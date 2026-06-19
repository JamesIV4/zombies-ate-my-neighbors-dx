-- Load a save slot and save a PNG screenshot so the radar inset can be seen in 4:3.
local slot = tonumber(os.getenv("ZAMNDX_SLOT") or "2") or 2
local state_path = string.format(
	"C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_%d.mss", slot)
local out = io.open(string.format("s:/Repos/zombies-ate-my-neighbors-dx/radar-shot-%d.log", slot), "w")
local snes = emu.memType.snesMemory
local loaded, frame = false, 0

local function load_state()
	if loaded then return end
	local f = io.open(state_path, "rb"); if not f then out:write("missing\n"); out:close(); emu.stop(2); return end
	local data = f:read("*a"); f:close()
	local ok, res = pcall(function() return emu.loadSavestate(data) end)
	loaded = ok and res
	out:write("load=" .. tostring(loaded) .. "\n"); out:flush()
	if not loaded then out:close(); emu.stop(2) end
	frame = 0
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 5 then
		local ok, res = pcall(function() return emu.takeScreenshot() end)
		out:write("screenshot ok=" .. tostring(ok) .. " res=" .. tostring(res) .. "\n")
		if ok and type(res) == "string" and #res > 100 then
			local p = string.format("s:/Repos/zombies-ate-my-neighbors-dx/radar-shot-%d.png", slot)
			local g = io.open(p, "wb"); g:write(res); g:close()
			out:write("wrote " .. p .. " bytes=" .. #res .. "\n")
		end
		out:close(); emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE, emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
