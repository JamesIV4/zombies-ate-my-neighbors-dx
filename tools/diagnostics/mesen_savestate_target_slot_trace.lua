-- Focused trace for the slots that pop in late in the user's savestate route.
-- Logs all meaningful slot-field writes so we can identify the initializer/gate.
local wram = emu.memType.snesWorkRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-target-slots.txt", "w")

local targets = {
	[0x1A3E] = true,
	[0x1A52] = true,
	[0x1A66] = true,
	[0x1A7A] = true,
	[0x1AA2] = true,
}

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

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function slot_summary(slot)
	local sx = signed16((r16(slot + 0x02) - r16(0x1B6A)) % 0x10000)
	local sy = signed16((r16(slot + 0x06) - r16(0x1B6C)) % 0x10000)
	return string.format(
		"slot=%04X type=%02X flags=%04X screen=(%d,%d) obj=(%04X,%04X) next=%04X spr=%04X:%04X sub=%04X",
		slot, r8(slot + 0x0E), r16(slot), sx, sy, r16(slot + 0x02), r16(slot + 0x06),
		r16(slot + 0x12), r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C))
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
	for slot in pairs(targets) do
		out:write("initial " .. slot_summary(slot) .. "\n")
	end
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
	end
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function on_slot_write(address, value)
	if not loaded then return end
	local off = address % 0x20000
	if off >= 0x10000 then off = off - 0x10000 end
	local slot = off - ((off - 0x185E) % 0x14)
	if not targets[slot] then return end
	local rel = off - slot
	if not rel_names[rel] then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	local pc = (cpu.pc or 0) + (cpu.k or 0) * 0x10000
	out:write(string.format(
		"write f=%03d pc=%06X rel=%02X(%s) value=%04X %s\n",
		frame, pc, rel, rel_names[rel], value % 0x10000, slot_summary(slot)))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 1 or frame == 19 or frame == 47 or frame == 86 or frame == 96 or frame == 107 or frame == 130 then
		out:write(string.format("frame %03d snapshot\n", frame))
		for slot in pairs(targets) do
			out:write("  " .. slot_summary(slot) .. "\n")
		end
		out:flush()
	end
	if frame >= 130 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addMemoryCallback(on_slot_write, emu.callbackType.write,
	0x185E, 0x1ADD, emu.cpuType.snes, wram)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
