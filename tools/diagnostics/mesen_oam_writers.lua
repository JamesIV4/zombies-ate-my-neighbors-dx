-- Find every routine that writes the OAM shadow ($7E:13BE-$15DD), empirically.
-- This reveals the item/survivor sprite renderer (and its bank) no matter how it
-- addresses memory, so we can find its 256px X-cull. Run on stock DX.
local wram = emu.memType.snesWorkRam
local writers = {}
local frame, gp = 0, nil
local active, dumped_state = false, false
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-oam-writers.txt", "w")

local function r8(a) return emu.read(a, wram) end

local function on_write(addr, value)
	local c = emu.getCpuState(emu.cpuType.snes)
	local key = (c.k or 0) * 0x10000 + (c.pc or 0)
	writers[key] = (writers[key] or 0) + 1
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local ph = math.floor((frame - gp) / 60) % 4
		if ph == 0 then emu.setInput({ right = true }, 0)
		elseif ph == 1 then emu.setInput({ down = true }, 0)
		elseif ph == 2 then emu.setInput({ left = true }, 0)
		else emu.setInput({ up = true }, 0) end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if r8(0x000E) == 2 and not active then
		active = true
		local ok, err = pcall(function()
			emu.addMemoryCallback(on_write, emu.callbackType.write, 0x13BE, 0x15DD,
				emu.cpuType.snes, emu.memType.snesWorkRam)
		end)
		out:write("register ok=" .. tostring(ok) .. " err=" .. tostring(err) .. "\n"); out:flush()
	end
	if gp and frame - gp >= 240 then
		local arr = {}
		for k, c in pairs(writers) do arr[#arr + 1] = { k, c } end
		table.sort(arr, function(a, b) return a[2] > b[2] end)
		out:write("OAM-shadow writer PCs (bank:pc = count), " .. #arr .. " unique:\n")
		for i = 1, math.min(#arr, 50) do
			out:write(string.format("  %02X:%04X = %d\n",
				math.floor(arr[i][1] / 0x10000), arr[i][1] % 0x10000, arr[i][2]))
		end
		out:close()
		emu.stop(0)
	elseif frame > 8000 then
		out:write("no gameplay\n"); out:close(); emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
