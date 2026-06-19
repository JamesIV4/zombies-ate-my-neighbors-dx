import pathlib

rom = (pathlib.Path(__file__).resolve().parent.parent.parent /
       "dist" / "Zombies Ate My Neighbors DX Widescreen.sfc").read_bytes()

# LoROM: file offset (bank>=0x80) -> snes  bank=0x80+(off//0x8000), addr=0x8000+(off%0x8000)
def snes(off):
    return (0x80 + off // 0x8000, 0x8000 + off % 0x8000)

stores = {0x8D: "STA abs", 0x9D: "STA abs,X", 0x99: "STA abs,Y",
          0x8F: "STA long", 0x9C: "STZ abs", 0x9E: "STZ abs,X"}

for reg, name in [(0x210B, "$210B BG12NBA"), (0x210C, "$210D BG34NBA"),
                  (0x2107, "$2107 BG1SC"), (0x2105, "$2105 BGMODE")]:
    lo, hi = reg & 0xFF, (reg >> 8) & 0xFF
    print(f"\n== writes to {name} ==")
    for off in range(len(rom) - 4):
        op = rom[off]
        if op in stores and rom[off + 1] == lo and rom[off + 2] == hi:
            b, a = snes(off)
            ctx = rom[max(0, off - 6):off + 3].hex(" ")
            print(f"  {b:02X}:{a:04X}  {stores[op]:<10} ctx {ctx}")
