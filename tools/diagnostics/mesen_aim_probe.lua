local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local matching_frames = 0
local tested_frames = 0

local function read8(address)
	return emu.read(address, wram)
end

local function read16(address)
	return emu.read16(address, wram)
end

local function set_input()
	local game_state = read8(0x000E)
	local player_active = read8(0x0D25)

	if game_state == 2 and player_active ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end

		local local_frame = frame - gameplay_frame
		local testing = local_frame >= 60 and local_frame < 180
		emu.setInput({
			left = testing,
			y = testing,
		}, 0)

		emu.write(0x1FFF0, testing and 1 or 0, wram)
		emu.write16(0x1FFF2, 0x0006, wram)
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

	if gameplay_frame then
		local local_frame = frame - gameplay_frame
		if local_frame >= 60 and local_frame < 180 then
			tested_frames = tested_frames + 1
			if read16(0x0124) == 0x000E and read16(0x0126) == 0x0006 then
				matching_frames = matching_frames + 1
			end
		elseif local_frame >= 180 then
			print(string.format(
				"aim probe: %d/%d frames moved left while facing right",
				matching_frames,
				tested_frames
			))
			if matching_frames >= 100 then
				print("aim probe passed")
				emu.stop(0)
			else
				print("aim probe failed")
				emu.stop(3)
			end
		end
	end

	if frame > 4000 then
		print("aim probe timed out")
		emu.stop(2)
	end
end

print("Mesen dual-stick aim probe started")
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
