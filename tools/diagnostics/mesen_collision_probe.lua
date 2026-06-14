local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local collision_count = 0

local function read8(address)
	return emu.read(address, wram)
end

local function collision_dispatch()
	collision_count = collision_count + 1
end

local function gameplay_input(local_frame)
	local phase = math.floor(local_frame / 120) % 4
	return {
		right = phase == 0,
		down = phase == 1,
		left = phase == 2,
		up = phase == 3,
		y = true,
	}
end

local function set_input()
	local game_state = read8(0x000E)
	local player_active = read8(0x0D25)

	if game_state == 2 and player_active ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end
		emu.setInput(gameplay_input(frame - gameplay_frame), 0)
	else
		local menu_phase = (frame - 760) % 180
		emu.setInput({
			start = frame >= 760 and menu_phase < 24,
			a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
			b = frame >= 760 and menu_phase >= 120 and menu_phase < 144,
		}, 0)
	end
end

local function end_frame()
	frame = frame + 1

	if gameplay_frame and frame - gameplay_frame >= 720 then
		print(string.format("collision dispatches: %d", collision_count))
		emu.stop(0)
	elseif frame > 5000 then
		print("collision probe timed out")
		emu.stop(2)
	end
end

print("Mesen collision probe started")
emu.addMemoryCallback(
	collision_dispatch,
	emu.callbackType.exec,
	0x80BE8F,
	0x80BE8F,
	emu.cpuType.snes,
	emu.memType.snesMemory
)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
