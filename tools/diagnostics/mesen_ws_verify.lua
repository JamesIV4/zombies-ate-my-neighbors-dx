-- Verify the widescreen pipeline produced correct data: after scrolling, the
-- gathered colbuf must match the level map, and the VRAM strip column must match
-- the colbuf (proving gather -> enqueue -> DMA worked).
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-ws-verify.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w7f(a) return emu.read(0x10000 + a, wram) end          -- $7F byte
local function w7f16(a) return w7f(a) + w7f(a + 1) * 256 end
local function vw(word) return emu.read(word * 2, vram) + emu.read(word * 2 + 1, vram) * 256 end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		emu.setInput({ down = (frame % 60 < 30), right = (frame % 60 >= 30) }, 0)
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function dump()
	local camcol = math.floor(r16(0x1B6A) / 8)
	local camrow = math.floor(r16(0x1B6C) / 8)
	local b2 = r16(0x00B2)
	out:write(string.format("camcol=%d camrow=%d rowstride=%04X lasttick=%04X\n",
		camcol, camrow, b2, w7f16(0xFFE0)))
	out:write("VRAMDEST[0..7]:")
	for i = 0, 7 do out:write(string.format(" %04X", w7f16(0xFFD0 + i * 2))) end
	out:write("\n")

	-- slot 4 = right strip, off = +32 (sidx>=4 -> sidx+28; sidx4 -> 32); mc=camcol+32
	local sidx = 4
	local mc = camcol + 32
	local dest = w7f16(0xFFD0 + sidx * 2)
	local bufoff = 0xFDC0 + sidx * 64
	out:write(string.format("\nslot %d mc=%d colbuf=$%04X dest=$%04X\n", sidx, mc, bufoff, dest))
	out:write("colbuf  :")
	for r = 0, 7 do out:write(string.format(" %04X", w7f16(bufoff + r * 2))) end
	out:write("\nVRAM col:")          -- VMAIN $81 wrote words dest+r*32
	for r = 0, 7 do out:write(string.format(" %04X", vw((dest + r * 32) % 0x8000))) end
	out:write("\nmap cell:")          -- cell(mc,row) = $7F:( rowbase[row] + mc*2 )
	for r = 0, 7 do
		local row = camrow + r
		local vrow = row % 32
		local rowbase = (r8(0x4328 + row * 2) + r8(0x4328 + row * 2 + 1) * 256)
		local cell = w7f16((rowbase + mc * 2) % 0x10000)
		out:write(string.format(" [%d]=%04X", vrow, cell))
	end
	out:write("\n")
	out:flush()
end

local function end_frame()
	frame = frame + 1
	if gp and (frame - gp) >= 400 then dump() out:close() emu.stop(0)
	elseif frame > 8000 then out:write("no gameplay\n") out:close() emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
