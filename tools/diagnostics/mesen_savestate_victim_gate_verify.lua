-- Diagnostic-only proof for the victim/neighborhood scanner gate. Load the user's
-- save, clear victim active flags and the already-scheduled cheerleader task, then
-- watch the bank-$81 scanner reschedule the left-side neighbor while still in the
-- widescreen strip.
local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-victim-gate.txt", "w")

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local function r16(a) return emu.read16(a & 0xFFFF, wram) end
local function w8(a, v) emu.write(a & 0xFFFF, v & 0xFF, wram) end
local function w16(a, v)
	w8(a, v)
	w8(a + 1, math.floor(v / 0x100))
end
local function sx(v)
	v = v & 0xFFFF
	if v >= 0x8000 then return v - 0x10000 end
	return v
end
local function d16(cpu, off)
	return r16(((cpu.d or 0) + off) & 0xFFFF)
end
local function pc(cpu)
	return ((cpu.k or 0) << 16) | (cpu.pc or 0)
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

	-- Clear victim state arrays used by $81:81F6 and disable the already-sleeping
	-- task at slot $26 so any cheerleader we see below was created by the scanner.
	for i = 0, 0x3F do
		w8(0x605A + i, 0)
		w8(0x609A + i, 0)
	end
	w16(0x1180 + 0x26, 0)
	out:write(string.format("after reset: cam=(%04X,%04X) disabledTask26 wait=%04X\n",
		r16(0x1B6A), r16(0x1B6C), r16(0x1180 + 0x26)))
	out:flush()
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function on_candidate()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	local x, y = d16(cpu, 0x16), d16(cpu, 0x18)
	out:write(string.format(
		"candidate f=%03d pc=%06X D=%04X idx=%04X pos=(%04X,%04X) screen=(%d,%d) cam=(%04X,%04X)\n",
		frame, pc(cpu), cpu.d or 0, d16(cpu, 0x10), x, y,
		sx(x - r16(0x1B6A)), sx(y - r16(0x1B6C)), r16(0x1B6A), r16(0x1B6C)))
	out:flush()
end

local function on_cheer()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	local x, y = d16(cpu, 0), d16(cpu, 2)
	out:write(string.format(
		"cheer-entry f=%03d D=%04X pos=(%04X,%04X) screen=(%d,%d) cam=(%04X,%04X)\n",
		frame, cpu.d or 0, x, y, sx(x - r16(0x1B6A)), sx(y - r16(0x1B6C)),
		r16(0x1B6A), r16(0x1B6C)))
	out:flush()
end

local function on_a13e()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	local x, y = d16(cpu, 0), d16(cpu, 2)
	out:write(string.format(
		"init f=%03d D=%04X sprite=%04X bank=%04X typeArg=%04X pos=(%04X,%04X) screen=(%d,%d)\n",
		frame, cpu.d or 0, cpu.a or 0, cpu.x or 0, d16(cpu, 0x1C),
		x, y, sx(x - r16(0x1B6A)), sx(y - r16(0x1B6C))))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame >= 80 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_candidate, emu.callbackType.exec, 0x8181A2, 0x8181A2,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_cheer, emu.callbackType.exec, 0x839C6D, 0x839C6D,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_a13e, emu.callbackType.exec, 0x83A13E, 0x83A13E,
	emu.cpuType.snes, snes)

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
