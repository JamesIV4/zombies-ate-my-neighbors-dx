-- Find how to read the SNES CPU PC/bank.
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-apitest.txt", "w")
local function keys(t)
	if type(t) ~= "table" then return "(" .. type(t) .. ")" end
	local r = {}
	for k, v in pairs(t) do r[#r + 1] = tostring(k) .. "=" .. type(v) end
	table.sort(r)
	return table.concat(r, ", ")
end
out:write("getState(): " .. keys(emu.getState()) .. "\n")
local ok1, s1 = pcall(emu.getState)
if ok1 and type(s1) == "table" then
	for k, v in pairs(s1) do if type(v) == "table" then out:write("  getState()." .. k .. ": " .. keys(v) .. "\n") end end
end
local ok2, s2 = pcall(function() return emu.getCpuState(emu.cpuType.snes) end)
out:write("getCpuState(snes) ok=" .. tostring(ok2) .. ": " .. keys(ok2 and s2 or nil) .. "\n")
out:close()
emu.stop(0)
