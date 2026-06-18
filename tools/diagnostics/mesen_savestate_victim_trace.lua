-- Load the user's widescreen savestate, hold left, and trace the victim/script
-- scanner that eventually starts the saved-scene cheerleader routine ($83:9C6D).
local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-victim-trace.txt", "w")

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local interesting_frames = {}
for i = 0, 40 do interesting_frames[i] = true end

local function r16(a) return emu.read16(a & 0xFFFF, wram) end
local function rs16(a)
	local v = r16(a)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end
local function rb(a) return emu.read(a, snes) end
local function r16s(a) return emu.read16(a, snes) end
local function sx(v)
	v = v & 0xFFFF
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function cpu_pc(cpu)
	return ((cpu.k or 0) << 16) | (cpu.pc or 0)
end

local function header(tag)
	local cpu = emu.getCpuState(emu.cpuType.snes)
	out:write(string.format(
		"%s f=%03d pc=%06X A=%04X X=%04X Y=%04X D=%04X DB=%02X SP=%04X cam=(%04X,%04X) script=(%04X:%04X %04X:%04X) 10=%04X 44=%04X 46=%04X 5c=%04X 5e=%04X 60=%04X 62=%04X de=%04X\n",
		tag, frame, cpu_pc(cpu), cpu.a or 0, cpu.x or 0, cpu.y or 0,
		cpu.d or 0, cpu.dbr or 0, cpu.sp or 0,
		r16(0x1B6A), r16(0x1B6C), r16(0x1B6E), r16(0x1B70),
		r16(0x1E74), r16(0x1E72), r16(0x1E78), r16(0x1E76),
		r16(0x0010), r16(0x0044), r16(0x0046), r16(0x005C), r16(0x005E),
		r16(0x0060), r16(0x0062), r16(0x00DE)))
end

local function d16(cpu, off)
	return r16(((cpu.d or 0) + off) & 0xFFFF)
end

local function dump_tasks()
	out:write("tasks at load:\n")
	for x = 0, 0x2E, 2 do
		local wait = r16(0x1180 + x)
		local sp = r16(0x11B0 + x)
		if wait ~= 0 or sp ~= 0 then
			out:write(string.format("  task=%02X wait=%04X sp=%04X stack:", x, wait, sp))
			for i = 1, 12 do
				out:write(string.format(" %02X", rb((sp + i) & 0xFFFF)))
			end
			out:write("\n")
		end
	end
end

local function stack_bytes(cpu)
	local sp = cpu.sp or 0
	out:write("  stack:")
	for i = 1, 16 do
		out:write(string.format(" %02X", rb((sp + i) & 0xFFFF)))
	end
	out:write("\n")
end

local function dump_script_window(ptr)
	out:write(string.format("  script @9F:%04X:", ptr & 0xFFFF))
	for i = 0, 15, 2 do
		out:write(string.format(" %04X", r16s(0x9F0000 + ((ptr + i) & 0xFFFF))))
	end
	out:write("\n")
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
	if loaded then dump_tasks() end
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
	end
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function maybe_log(tag)
	if not loaded or not interesting_frames[frame] then return end
	header(tag)
	out:flush()
end

local function on_c259()
	maybe_log("scan-entry")
end

local function on_c29c()
	if not loaded or not interesting_frames[frame] then return end
	header("cmd-read")
	local ptr = r16(0x0044)
	out:write(string.format("  x44=%04X word=%04X next=%04X\n",
		ptr, r16s(0x9F0000 + ptr), r16s(0x9F0002 + ptr)))
	dump_script_window(ptr)
	out:flush()
end

local function on_c2a8()
	if not loaded or not interesting_frames[frame] then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	header("cmd-dispatch")
	local x = cpu.x or 0
	out:write(string.format("  command-index=%04X handler=%04X\n",
		x, r16s(0x82C346 + x)))
	out:flush()
end

local function on_9c6d()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	header("cheer-entry")
	stack_bytes(cpu)
	out:write(string.format(
		"  dp=%04X x=%04X(%d) y=%04X(%d) screen=(%d,%d) a=%04X xreg=%04X yreg=%04X\n",
		cpu.d or 0, d16(cpu, 0), sx(d16(cpu, 0)), d16(cpu, 2), sx(d16(cpu, 2)),
		sx(d16(cpu, 0) - r16(0x1B6A)), sx(d16(cpu, 2) - r16(0x1B6C)),
		cpu.a or 0, cpu.x or 0, cpu.y or 0))
	out:flush()
end

local function on_a13e()
	if not loaded then return end
	local cpu = emu.getCpuState(emu.cpuType.snes)
	header("init-a13e")
	stack_bytes(cpu)
	out:write(string.format(
		"  dp=%04X x=%04X y=%04X screen=(%d,%d) sprite=%04X bank=%04X typeArg=%04X\n",
		cpu.d or 0, d16(cpu, 0), d16(cpu, 2), sx(d16(cpu, 0) - r16(0x1B6A)),
		sx(d16(cpu, 2) - r16(0x1B6C)), cpu.a or 0, cpu.x or 0, d16(cpu, 0x1C)))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame >= 90 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)

emu.addMemoryCallback(on_c259, emu.callbackType.exec, 0x82C259, 0x82C259,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_c29c, emu.callbackType.exec, 0x82C29C, 0x82C29C,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_c2a8, emu.callbackType.exec, 0x82C2A8, 0x82C2A8,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_9c6d, emu.callbackType.exec, 0x839C6D, 0x839C6D,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_a13e, emu.callbackType.exec, 0x83A13E, 0x83A13E,
	emu.cpuType.snes, snes)

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
