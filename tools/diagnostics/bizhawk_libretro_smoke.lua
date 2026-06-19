-- Smoke-test BizHawk's command-line OpenAdvanced libretro launch path.
-- Run with EmuHawk.exe --lua this_file.lua "*Libretro*{...}".

local out = io.open("bizhawk-libretro-smoke.txt", "w")

local function write(line)
	if out then
		out:write(line .. "\n")
		out:flush()
	end
	console.log(line)
end

for frame = 1, 90 do
	emu.frameadvance()
end

joypad.set({ ["P1 RetroPad Y"] = true })
emu.frameadvance()
local buttons = joypad.getwithmovie()

local ok_system, system = pcall(function()
	return emu.getsystemid()
end)
local ok_rom, rom = pcall(function()
	return gameinfo.getromname()
end)

write("system=" .. tostring(ok_system and system or "unknown"))
write("rom=" .. tostring(ok_rom and rom or "unknown"))
write("retropad_y=" .. tostring(buttons["P1 RetroPad Y"]))

if out then
	out:close()
end

client.exitCode(0)
client.exit()
