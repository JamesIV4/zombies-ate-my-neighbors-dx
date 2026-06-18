-- Synthetic verification for the type-$05 render-list relax.
-- Clone an active type-$05 object into the left widescreen strip without linking it
-- through $1B5E. The patched build should append it to $137E and draw strip OAM.
local wram = emu.memType.snesWorkRam
local oam = emu.memType.snesSpriteRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-type05-inject.txt", "w")

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14
local injected, src_slot, dst_slot = false, nil, nil
local saw_render, peak_left = false, 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w8(a, v) emu.write(a, v % 0x100, wram) end
local function w16(a, v)
	w8(a, v)
	w8(a + 1, math.floor(v / 0x100))
end

local function sprite_x9(i)
	local lo = emu.read(i * 4, oam)
	local hbyte = emu.read(512 + math.floor(i / 4), oam)
	local xhigh = math.floor(hbyte / 2 ^ ((i % 4) * 2)) % 2
	return lo + xhigh * 256
end

local function count_left_strip()
	local left = 0
	for i = 0, 127 do
		local y = emu.read(i * 4 + 1, oam)
		if y < 0xE0 then
			local x = sprite_x9(i)
			if x >= 0x1B0 and x <= 0x1F0 then left = left + 1 end
		end
	end
	return left
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

local function find_source()
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		if r8(slot + 0x0E) == 0x05 and r16(slot) >= 0x8000 then return slot end
	end
	return nil
end

local function find_free(except)
	for slot = SLOT_LAST, SLOT_FIRST, -SLOT_SIZE do
		if slot ~= except and r16(slot) == 0 then return slot end
	end
	return nil
end

local function inject()
	src_slot = find_source()
	dst_slot = src_slot and find_free(src_slot) or nil
	if not dst_slot then
		out:write("inject=no-slot\n")
		return
	end
	for i = 0, SLOT_SIZE - 1 do
		w8(dst_slot + i, r8(src_slot + i))
	end
	w16(dst_slot + 0x00, r16(src_slot) | 0x8000)
	w16(dst_slot + 0x02, (r16(0x1B6A) - 0x28) % 0x10000)
	w16(dst_slot + 0x06, (r16(0x1B6C) + 0x78) % 0x10000)
	w16(dst_slot + 0x0E, 0x0005)
	w16(dst_slot + 0x12, 0x0000)
	injected = true
	out:write(string.format("inject=ok src=%04X dst=%04X cam=(%04X,%04X)\n",
		src_slot, dst_slot, r16(0x1B6A), r16(0x1B6C)))
	out:flush()
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		emu.setInput({}, 0)
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if gp and not injected and frame - gp >= 80 then inject() end
	if injected then
		if in_render(dst_slot) then saw_render = true end
		local left = count_left_strip()
		if left > peak_left then peak_left = left end
	end
	if injected and frame - gp >= 180 then
		out:write(string.format("saw_render=%s peak_left_strip_oam=%d\n", tostring(saw_render), peak_left))
		out:close()
		emu.stop((saw_render and peak_left > 0) and 0 or 1)
	elseif frame > 8000 then
		out:write("no gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
