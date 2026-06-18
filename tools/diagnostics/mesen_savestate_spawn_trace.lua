-- Load the user's widescreen savestate, hold left, and trace object-slot writes
-- around actors that enter the viewport late. This is meant to find the upstream
-- activation/proximity gate, not the downstream OAM sprite cull.
local wram = emu.memType.snesWorkRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-spawn-trace.txt", "w")

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14

local loaded = false
local frame = 0
local write_count = 0
local active_seen = {}
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local rel_names = {
	[0x00] = "flags.lo", [0x01] = "flags.hi",
	[0x02] = "x.lo",     [0x03] = "x.hi",
	[0x06] = "y.lo",     [0x07] = "y.hi",
	[0x08] = "spr.lo",   [0x09] = "spr.hi",
	[0x0A] = "bank.lo",  [0x0B] = "bank.hi",
	[0x0C] = "sub.lo",   [0x0D] = "sub.hi",
	[0x0E] = "type.lo",  [0x0F] = "type.hi",
	[0x12] = "next.lo",  [0x13] = "next.hi",
}

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function screen_x(slot)
	return signed16((r16(slot + 0x02) - r16(0x1B6A)) % 0x10000)
end

local function screen_y(slot)
	return signed16((r16(slot + 0x06) - r16(0x1B6C)) % 0x10000)
end

local function near_view(slot)
	local sx, sy = screen_x(slot), screen_y(slot)
	return sx >= -160 and sx < 448 and sy >= -160 and sy < 448
end

local function slot_summary(slot)
	return string.format(
		"slot=%04X type=%02X flags=%04X screen=(%d,%d) obj=(%04X,%04X) next=%04X spr=%04X:%04X sub=%04X",
		slot, r8(slot + 0x0E), r16(slot), screen_x(slot), screen_y(slot),
		r16(slot + 0x02), r16(slot + 0x06), r16(slot + 0x12),
		r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C))
end

local function load_state()
	if loaded then return end
	if not state_data then
		out:write("load=false missing-state\n")
		out:close()
		emu.stop(2)
		return
	end
	local ok, result = pcall(function() return emu.loadSavestate(state_data) end)
	loaded = ok and result
	out:write("load=" .. tostring(loaded) .. " pcall=" .. tostring(ok) ..
		" bytes=" .. tostring(#state_data) .. "\n")
	if not loaded then
		out:close()
		emu.stop(2)
		return
	end
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		active_seen[slot] = r16(slot) >= 0x8000
		if active_seen[slot] and near_view(slot) then
			out:write("initial " .. slot_summary(slot) .. "\n")
		end
	end
	out:flush()
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function on_slot_write(address, value)
	if not loaded then return end
	if write_count >= 240 then return end
	local off = address % 0x20000
	if off >= 0x10000 then off = off - 0x10000 end
	if off < SLOT_FIRST or off > SLOT_LAST + SLOT_SIZE - 1 then return end
	local rel = (off - SLOT_FIRST) % SLOT_SIZE
	if not rel_names[rel] then return end
	local slot = off - rel
	if r16(slot) < 0x8000 and not active_seen[slot] then return end
	if not near_view(slot) then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	write_count = write_count + 1
	out:write(string.format(
		"write f=%03d pc=%06X rel=%02X(%s) value=%04X %s\n",
		frame, cpu.pc or 0, rel, rel_names[rel], value % 0x10000, slot_summary(slot)))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		local active = r16(slot) >= 0x8000
		if active and not active_seen[slot] and near_view(slot) then
			out:write(string.format("new-active f=%03d %s\n", frame, slot_summary(slot)))
			out:flush()
		end
		active_seen[slot] = active
	end
	if frame >= 160 then
		out:write("writes_logged=" .. tostring(write_count) .. "\n")
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addMemoryCallback(on_slot_write, emu.callbackType.write,
	SLOT_FIRST, SLOT_LAST + SLOT_SIZE - 1, emu.cpuType.snes, wram)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
