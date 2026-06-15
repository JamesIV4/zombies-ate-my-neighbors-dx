local wram = emu.memType.snesWorkRam
local snes_memory = emu.memType.snesMemory
local snes_cpu = emu.cpuType.snes
local frame = 0
local loaded = false
local output = io.open("mesen-state-probe.txt", "w")
local state_file = io.open(
	"C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX_11.mss",
	"rb"
)
local state_data = state_file:read("*a")
state_file:close()

local function load_state()
	if loaded then
		return
	end
	loaded = emu.loadSavestate(state_data)
	output:write("loaded=" .. tostring(loaded) .. "\n")
	output:flush()
end

local function end_frame()
	frame = frame + 1
	if loaded and frame % 10 == 0 then
		local state = emu.getState()
		output:write(string.format(
			"frame=%d game=%02X active=%02X x=%04X y=%04X pc=%06X dp=%04X\n",
			frame,
			emu.read(0x000E, wram),
			emu.read(0x0D25, wram),
			emu.read16(0x0130, wram),
			emu.read16(0x0132, wram),
			state["cpu.pc"] or 0,
			state["cpu.d"] or 0
		))
		output:flush()
	end
	if loaded and frame >= 60 then
		output:close()
		emu.stop(0)
	elseif frame >= 300 then
		output:close()
		emu.stop(2)
	end
end

emu.addMemoryCallback(
	load_state,
	emu.callbackType.exec,
	0x0080AE,
	0x0080AE,
	snes_cpu,
	snes_memory
)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
