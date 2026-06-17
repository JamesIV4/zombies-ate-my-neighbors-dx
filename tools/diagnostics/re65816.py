#!/usr/bin/env python3
"""Static reverse-engineering helper for the ZAMN (USA) LoROM image.

Two jobs:
  * scan  - locate writes to specific PPU/DMA registers (find render code)
  * dis   - disassemble a 65816 range given a SNES address

LoROM mapping (headerless): SNES $bb:8000-$bb:FFFF  ->  file (bb&0x7F)*0x8000 + (addr-0x8000)
The game image is banks $80-$9F mirrored to $00-$1F; we treat file offsets directly.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

DEFAULT_ROM = Path("Zombies Ate My Neighbors (USA).sfc")


def file_to_snes(offset: int) -> tuple[int, int]:
    bank = 0x80 + (offset // 0x8000)
    addr = 0x8000 + (offset % 0x8000)
    return bank, addr


def snes_to_file(bank: int, addr: int) -> int:
    return (bank & 0x7F) * 0x8000 + (addr - 0x8000)


# --- minimal but practical 65816 opcode table -----------------------------
# mode codes: imp, imm_m (A-size), imm_x (X-size), imm8, acc,
# dp, dpx, dpy, idp, idx, idy, idl, idly,
# abs, abx, aby, abl, ablx, ind, iax, indl,
# rel, rell, sr, sry, bm (block move)
OPCODES = {
    0x00: ("BRK", "imm8"), 0x01: ("ORA", "idx"), 0x02: ("COP", "imm8"),
    0x03: ("ORA", "sr"), 0x04: ("TSB", "dp"), 0x05: ("ORA", "dp"),
    0x06: ("ASL", "dp"), 0x07: ("ORA", "idl"), 0x08: ("PHP", "imp"),
    0x09: ("ORA", "imm_m"), 0x0A: ("ASL", "acc"), 0x0B: ("PHD", "imp"),
    0x0C: ("TSB", "abs"), 0x0D: ("ORA", "abs"), 0x0E: ("ASL", "abs"),
    0x0F: ("ORA", "abl"),
    0x10: ("BPL", "rel"), 0x11: ("ORA", "idy"), 0x12: ("ORA", "idp"),
    0x13: ("ORA", "sry"), 0x14: ("TRB", "dp"), 0x15: ("ORA", "dpx"),
    0x16: ("ASL", "dpx"), 0x17: ("ORA", "idly"), 0x18: ("CLC", "imp"),
    0x19: ("ORA", "aby"), 0x1A: ("INC", "acc"), 0x1B: ("TCS", "imp"),
    0x1C: ("TRB", "abs"), 0x1D: ("ORA", "abx"), 0x1E: ("ASL", "abx"),
    0x1F: ("ORA", "ablx"),
    0x20: ("JSR", "abs"), 0x21: ("AND", "idx"), 0x22: ("JSL", "abl"),
    0x23: ("AND", "sr"), 0x24: ("BIT", "dp"), 0x25: ("AND", "dp"),
    0x26: ("ROL", "dp"), 0x27: ("AND", "idl"), 0x28: ("PLP", "imp"),
    0x29: ("AND", "imm_m"), 0x2A: ("ROL", "acc"), 0x2B: ("PLD", "imp"),
    0x2C: ("BIT", "abs"), 0x2D: ("AND", "abs"), 0x2E: ("ROL", "abs"),
    0x2F: ("AND", "abl"),
    0x30: ("BMI", "rel"), 0x31: ("AND", "idy"), 0x32: ("AND", "idp"),
    0x33: ("AND", "sry"), 0x34: ("BIT", "dpx"), 0x35: ("AND", "dpx"),
    0x36: ("ROL", "dpx"), 0x37: ("AND", "idly"), 0x38: ("SEC", "imp"),
    0x39: ("AND", "aby"), 0x3A: ("DEC", "acc"), 0x3B: ("TSC", "imp"),
    0x3C: ("BIT", "abx"), 0x3D: ("AND", "abx"), 0x3E: ("ROL", "abx"),
    0x3F: ("AND", "ablx"),
    0x40: ("RTI", "imp"), 0x41: ("EOR", "idx"), 0x42: ("WDM", "imm8"),
    0x43: ("EOR", "sr"), 0x44: ("MVP", "bm"), 0x45: ("EOR", "dp"),
    0x46: ("LSR", "dp"), 0x47: ("EOR", "idl"), 0x48: ("PHA", "imp"),
    0x49: ("EOR", "imm_m"), 0x4A: ("LSR", "acc"), 0x4B: ("PHK", "imp"),
    0x4C: ("JMP", "abs"), 0x4D: ("EOR", "abs"), 0x4E: ("LSR", "abs"),
    0x4F: ("EOR", "abl"),
    0x50: ("BVC", "rel"), 0x51: ("EOR", "idy"), 0x52: ("EOR", "idp"),
    0x53: ("EOR", "sry"), 0x54: ("MVN", "bm"), 0x55: ("EOR", "dpx"),
    0x56: ("LSR", "dpx"), 0x57: ("EOR", "idly"), 0x58: ("CLI", "imp"),
    0x59: ("EOR", "aby"), 0x5A: ("PHY", "imp"), 0x5B: ("TCD", "imp"),
    0x5C: ("JML", "abl"), 0x5D: ("EOR", "abx"), 0x5E: ("LSR", "abx"),
    0x5F: ("EOR", "ablx"),
    0x60: ("RTS", "imp"), 0x61: ("ADC", "idx"), 0x62: ("PER", "rell"),
    0x63: ("ADC", "sr"), 0x64: ("STZ", "dp"), 0x65: ("ADC", "dp"),
    0x66: ("ROR", "dp"), 0x67: ("ADC", "idl"), 0x68: ("PLA", "imp"),
    0x69: ("ADC", "imm_m"), 0x6A: ("ROR", "acc"), 0x6B: ("RTL", "imp"),
    0x6C: ("JMP", "ind"), 0x6D: ("ADC", "abs"), 0x6E: ("ROR", "abs"),
    0x6F: ("ADC", "abl"),
    0x70: ("BVS", "rel"), 0x71: ("ADC", "idy"), 0x72: ("ADC", "idp"),
    0x73: ("ADC", "sry"), 0x74: ("STZ", "dpx"), 0x75: ("ADC", "dpx"),
    0x76: ("ROR", "dpx"), 0x77: ("ADC", "idly"), 0x78: ("SEI", "imp"),
    0x79: ("ADC", "aby"), 0x7A: ("PLY", "imp"), 0x7B: ("TDC", "imp"),
    0x7C: ("JMP", "iax"), 0x7D: ("ADC", "abx"), 0x7E: ("ROR", "abx"),
    0x7F: ("ADC", "ablx"),
    0x80: ("BRA", "rel"), 0x81: ("STA", "idx"), 0x82: ("BRL", "rell"),
    0x83: ("STA", "sr"), 0x84: ("STY", "dp"), 0x85: ("STA", "dp"),
    0x86: ("STX", "dp"), 0x87: ("STA", "idl"), 0x88: ("DEY", "imp"),
    0x89: ("BIT", "imm_m"), 0x8A: ("TXA", "imp"), 0x8B: ("PHB", "imp"),
    0x8C: ("STY", "abs"), 0x8D: ("STA", "abs"), 0x8E: ("STX", "abs"),
    0x8F: ("STA", "abl"),
    0x90: ("BCC", "rel"), 0x91: ("STA", "idy"), 0x92: ("STA", "idp"),
    0x93: ("STA", "sry"), 0x94: ("STY", "dpx"), 0x95: ("STA", "dpx"),
    0x96: ("STX", "dpy"), 0x97: ("STA", "idly"), 0x98: ("TYA", "imp"),
    0x99: ("STA", "aby"), 0x9A: ("TXS", "imp"), 0x9B: ("TXY", "imp"),
    0x9C: ("STZ", "abs"), 0x9D: ("STA", "abx"), 0x9E: ("STZ", "abx"),
    0x9F: ("STA", "ablx"),
    0xA0: ("LDY", "imm_x"), 0xA1: ("LDA", "idx"), 0xA2: ("LDX", "imm_x"),
    0xA3: ("LDA", "sr"), 0xA4: ("LDY", "dp"), 0xA5: ("LDA", "dp"),
    0xA6: ("LDX", "dp"), 0xA7: ("LDA", "idl"), 0xA8: ("TAY", "imp"),
    0xA9: ("LDA", "imm_m"), 0xAA: ("TAX", "imp"), 0xAB: ("PLB", "imp"),
    0xAC: ("LDY", "abs"), 0xAD: ("LDA", "abs"), 0xAE: ("LDX", "abs"),
    0xAF: ("LDA", "abl"),
    0xB0: ("BCS", "rel"), 0xB1: ("LDA", "idy"), 0xB2: ("LDA", "idp"),
    0xB3: ("LDA", "sry"), 0xB4: ("LDY", "dpx"), 0xB5: ("LDA", "dpx"),
    0xB6: ("LDX", "dpy"), 0xB7: ("LDA", "idly"), 0xB8: ("CLV", "imp"),
    0xB9: ("LDA", "aby"), 0xBA: ("TSX", "imp"), 0xBB: ("TYX", "imp"),
    0xBC: ("LDY", "abx"), 0xBD: ("LDA", "abx"), 0xBE: ("LDX", "aby"),
    0xBF: ("LDA", "ablx"),
    0xC0: ("CPY", "imm_x"), 0xC1: ("CMP", "idx"), 0xC2: ("REP", "imm8"),
    0xC3: ("CMP", "sr"), 0xC4: ("CPY", "dp"), 0xC5: ("CMP", "dp"),
    0xC6: ("DEC", "dp"), 0xC7: ("CMP", "idl"), 0xC8: ("INY", "imp"),
    0xC9: ("CMP", "imm_m"), 0xCA: ("DEX", "imp"), 0xCB: ("WAI", "imp"),
    0xCC: ("CPY", "abs"), 0xCD: ("CMP", "abs"), 0xCE: ("DEC", "abs"),
    0xCF: ("CMP", "abl"),
    0xD0: ("BNE", "rel"), 0xD1: ("CMP", "idy"), 0xD2: ("CMP", "idp"),
    0xD3: ("CMP", "sry"), 0xD4: ("PEI", "dp"), 0xD5: ("CMP", "dpx"),
    0xD6: ("DEC", "dpx"), 0xD7: ("CMP", "idly"), 0xD8: ("CLD", "imp"),
    0xD9: ("CMP", "aby"), 0xDA: ("PHX", "imp"), 0xDB: ("STP", "imp"),
    0xDC: ("JML", "indl"), 0xDD: ("CMP", "abx"), 0xDE: ("DEC", "abx"),
    0xDF: ("CMP", "ablx"),
    0xE0: ("CPX", "imm_x"), 0xE1: ("SBC", "idx"), 0xE2: ("SEP", "imm8"),
    0xE3: ("SBC", "sr"), 0xE4: ("CPX", "dp"), 0xE5: ("SBC", "dp"),
    0xE6: ("INC", "dp"), 0xE7: ("SBC", "idl"), 0xE8: ("INX", "imp"),
    0xE9: ("SBC", "imm_m"), 0xEA: ("NOP", "imp"), 0xEB: ("XBA", "imp"),
    0xEC: ("CPX", "abs"), 0xED: ("SBC", "abs"), 0xEE: ("INC", "abs"),
    0xEF: ("SBC", "abl"),
    0xF0: ("BEQ", "rel"), 0xF1: ("SBC", "idy"), 0xF2: ("SBC", "idp"),
    0xF3: ("SBC", "sry"), 0xF4: ("PEA", "abs"), 0xF5: ("SBC", "dpx"),
    0xF6: ("INC", "dpx"), 0xF7: ("SBC", "idly"), 0xF8: ("SED", "imp"),
    0xF9: ("SBC", "aby"), 0xFA: ("PLX", "imp"), 0xFB: ("XCE", "imp"),
    0xFC: ("JSR", "iax"), 0xFD: ("SBC", "abx"), 0xFE: ("INC", "abx"),
    0xFF: ("SBC", "ablx"),
}

# operand byte length per mode (immediates resolved at runtime via M/X)
FIXED_LEN = {
    "imp": 0, "acc": 0,
    "imm8": 1, "dp": 1, "dpx": 1, "dpy": 1, "idp": 1, "idx": 1, "idy": 1,
    "idl": 1, "idly": 1, "sr": 1, "sry": 1, "rel": 1,
    "abs": 2, "abx": 2, "aby": 2, "ind": 2, "iax": 2, "rell": 2, "bm": 2,
    "abl": 3, "ablx": 3, "indl": 3,
}


def fmt_operand(mode, operand, pc, mlen, xlen):
    if mode in ("imp", "acc"):
        return ""
    if mode == "imm_m":
        return f"#${operand:0{mlen*2}X}"
    if mode == "imm_x":
        return f"#${operand:0{xlen*2}X}"
    if mode == "imm8":
        return f"#${operand:02X}"
    if mode == "dp":
        return f"${operand:02X}"
    if mode == "dpx":
        return f"${operand:02X},X"
    if mode == "dpy":
        return f"${operand:02X},Y"
    if mode == "idp":
        return f"(${operand:02X})"
    if mode == "idx":
        return f"(${operand:02X},X)"
    if mode == "idy":
        return f"(${operand:02X}),Y"
    if mode == "idl":
        return f"[${operand:02X}]"
    if mode == "idly":
        return f"[${operand:02X}],Y"
    if mode == "sr":
        return f"${operand:02X},S"
    if mode == "sry":
        return f"(${operand:02X},S),Y"
    if mode == "abs":
        return f"${operand:04X}"
    if mode == "abx":
        return f"${operand:04X},X"
    if mode == "aby":
        return f"${operand:04X},Y"
    if mode == "ind":
        return f"(${operand:04X})"
    if mode == "iax":
        return f"(${operand:04X},X)"
    if mode == "indl":
        return f"[${operand:04X}]"
    if mode == "abl":
        return f"${operand:06X}"
    if mode == "ablx":
        return f"${operand:06X},X"
    if mode == "rel":
        dest = (pc + 2 + ((operand ^ 0x80) - 0x80)) & 0xFFFF
        return f"${dest:04X}"
    if mode == "rell":
        dest = (pc + 3 + ((operand ^ 0x8000) - 0x8000)) & 0xFFFF
        return f"${dest:04X}"
    if mode == "bm":
        return f"#${operand & 0xFF:02X},#${operand >> 8:02X}"
    return f"${operand:X}"


def disassemble(rom, start_off, count, m=1, x=1):
    """Disassemble `count` instructions starting at file offset start_off.
    m,x: initial accumulator/index widths in bytes (1=8-bit,2=16-bit)."""
    off = start_off
    lines = []
    for _ in range(count):
        if off >= len(rom):
            break
        bank, addr = file_to_snes(off)
        op = rom[off]
        name, mode = OPCODES[op]
        if mode == "imm_m":
            olen = m
        elif mode == "imm_x":
            olen = x
        else:
            olen = FIXED_LEN[mode]
        operand = 0
        for i in range(olen):
            operand |= rom[off + 1 + i] << (8 * i)
        text = fmt_operand(mode, operand, addr, m, x)
        raw = " ".join(f"{rom[off + i]:02X}" for i in range(1 + olen))
        lines.append(f"${bank:02X}:{addr:04X}  {raw:<14}  {name} {text}".rstrip())
        # track M/X width from REP/SEP for correct immediate sizing
        if name == "SEP":
            if operand & 0x20:
                m = 1
            if operand & 0x10:
                x = 1
        elif name == "REP":
            if operand & 0x20:
                m = 2
            if operand & 0x10:
                x = 2
        off += 1 + olen
    return lines


def scan_register_writes(rom, registers):
    """Find STA/STZ/STX/STY abs (and abx) writes targeting given $21xx/$43xx regs."""
    hits = {r: [] for r in registers}
    store_abs = {0x8D: "STA", 0x9C: "STZ", 0x8E: "STX", 0x8C: "STY",
                 0x9D: "STA,X", 0x9E: "STZ,X"}
    for off in range(len(rom) - 2):
        op = rom[off]
        if op in store_abs:
            target = rom[off + 1] | (rom[off + 2] << 8)
            if target in hits:
                bank, addr = file_to_snes(off)
                hits[target].append((bank, addr, store_abs[op]))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rom", default=str(DEFAULT_ROM), type=Path)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ds = sub.add_parser("dis")
    ds.add_argument("addr", help="SNES address bb:aaaa or 0xfileoffset")
    ds.add_argument("count", type=int, nargs="?", default=40)
    ds.add_argument("-m", type=int, default=1)
    ds.add_argument("-x", type=int, default=1)
    sc = sub.add_parser("scan")
    sc.add_argument("regs", nargs="*", help="hex register addresses e.g. 210D 2104")
    args = ap.parse_args()
    rom = args.rom.read_bytes()

    if args.cmd == "dis":
        a = args.addr
        if ":" in a:
            bank, addr = a.split(":")
            off = snes_to_file(int(bank, 16), int(addr, 16))
        elif a.lower().startswith("0x"):
            off = int(a, 16)
        else:
            off = int(a, 16)
        for line in disassemble(rom, off, args.count, args.m, args.x):
            print(line)
    elif args.cmd == "scan":
        regs = [int(r, 16) for r in args.regs] or [
            0x210D, 0x210E, 0x210F, 0x2110, 0x2102, 0x2103, 0x2104,
            0x2116, 0x2117, 0x2118, 0x2119, 0x420B, 0x4300, 0x4310,
        ]
        hits = scan_register_writes(rom, regs)
        names = {
            0x210D: "BG1HOFS", 0x210E: "BG1VOFS", 0x210F: "BG2HOFS",
            0x2110: "BG2VOFS", 0x2102: "OAMADDL", 0x2103: "OAMADDH",
            0x2104: "OAMDATA", 0x2116: "VMADDL", 0x2117: "VMADDH",
            0x2118: "VMDATAL", 0x2119: "VMDATAH", 0x420B: "MDMAEN",
            0x4300: "DMAP0", 0x4310: "DMAP1",
        }
        for reg in regs:
            label = names.get(reg, f"${reg:04X}")
            sites = hits[reg]
            print(f"\n== {label} (${reg:04X}) : {len(sites)} write site(s) ==")
            for bank, addr, kind in sites:
                print(f"   ${bank:02X}:{addr:04X}  {kind}")


if __name__ == "__main__":
    raise SystemExit(main())
