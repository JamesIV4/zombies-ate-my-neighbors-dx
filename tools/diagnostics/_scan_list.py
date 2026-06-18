import sys
rom = open("dist/Zombies Ate My Neighbors DX.sfc", "rb").read()
sto = {0x8D: "STA", 0x9D: "STA,X", 0x99: "STA,Y", 0x9E: "STZ,X", 0x9C: "STZ", 0x8E: "STX", 0x8C: "STY"}


def scan(lo, hi, label):
    print(f"writes to {label}:")
    for off in range(0, len(rom) - 3):
        if rom[off] in sto and rom[off + 1] == lo and rom[off + 2] == hi:
            bank = 0x80 + (off // 0x8000)
            snes = 0x8000 + (off % 0x8000)
            ctx = rom[max(0, off - 7):off + 3].hex(" ")
            print(f"  {bank:02X}:{snes:04X}  {sto[rom[off]]:<5} ctx {ctx}")


scan(0x7E, 0x13, "$137E (render list)")
scan(0x5E, 0x1B, "$1B5E (list head)")
