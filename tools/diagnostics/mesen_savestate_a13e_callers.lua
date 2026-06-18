-- Identify which bank-$83 call site invokes the shared $83:A13E initializer
-- while walking left from the user's savestate.
local wram = emu.memType.snesWorkRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-a13e-callers.txt", "w")

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local callers = {
	0x8396AE, 0x83978B, 0x83987D, 0x839952, 0x839A9E, 0x839BC2,
	0x839C82, 0x839D15, 0x839E2A, 0x839ED3, 0x839FF7,
}

local function r16(a) return emu.read16(a, wram) end

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
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
	end
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function on_call()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	local pc = (cpu.pc or 0) + (cpu.k or 0) * 0x10000
	out:write(string.format(
		"call f=%03d pc=%06X A=%04X X=%04X Y=%04X cam=(%04X,%04X)\n",
		frame, pc, cpu.a or 0, cpu.x or 0, cpu.y or 0, r16(0x1B6A), r16(0x1B6C)))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame >= 130 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
for _, addr in ipairs(callers) do
	emu.addMemoryCallback(on_call, emu.callbackType.exec, addr, addr,
		emu.cpuType.snes, emu.memType.snesMemory)
end
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
