#!/usr/bin/env python3
"""Tiny two-pass 65816 assembler for ZAMN DX ROM hooks.

Deliberately small: supports the instructions/addressing modes the hooks need,
with labels for branches and jumps. Immediate and address widths are taken from
the literal's hex-digit count, so the source is explicit and unambiguous:
    LDA #$00     -> 8-bit immediate      LDA #$0000   -> 16-bit immediate
    LDA $12      -> direct page          LDA $1234    -> absolute
    LDA $7E4328  -> absolute long        LDA $7E4328,X-> long,X
Branches/JMP/JSR/JML/JSL take a label or $literal.

assemble(source, org) -> (bytes, {label: snes_addr}).
"""
from __future__ import annotations

import re

# (mnemonic, mode) -> opcode.  Modes match the assembler's parser below.
# imm covers M/X/8-bit immediates; width comes from the operand's digit count.
_TABLE = {
    ("BRK", "imm"): 0x00, ("ORA", "idx"): 0x01, ("COP", "imm"): 0x02,
    ("ORA", "sr"): 0x03, ("TSB", "dp"): 0x04, ("ORA", "dp"): 0x05,
    ("ASL", "dp"): 0x06, ("ORA", "idl"): 0x07, ("PHP", "imp"): 0x08,
    ("ORA", "imm"): 0x09, ("ASL", "acc"): 0x0A, ("PHD", "imp"): 0x0B,
    ("TSB", "abs"): 0x0C, ("ORA", "abs"): 0x0D, ("ASL", "abs"): 0x0E,
    ("ORA", "abl"): 0x0F, ("BPL", "rel"): 0x10, ("ORA", "idy"): 0x11,
    ("ORA", "idp"): 0x12, ("ORA", "sry"): 0x13, ("TRB", "dp"): 0x14,
    ("ORA", "dpx"): 0x15, ("ASL", "dpx"): 0x16, ("ORA", "idly"): 0x17,
    ("CLC", "imp"): 0x18, ("ORA", "aby"): 0x19, ("INC", "acc"): 0x1A,
    ("TCS", "imp"): 0x1B, ("TRB", "abs"): 0x1C, ("ORA", "abx"): 0x1D,
    ("ASL", "abx"): 0x1E, ("ORA", "ablx"): 0x1F, ("JSR", "abs"): 0x20,
    ("AND", "idx"): 0x21, ("JSL", "abl"): 0x22, ("AND", "sr"): 0x23,
    ("BIT", "dp"): 0x24, ("AND", "dp"): 0x25, ("ROL", "dp"): 0x26,
    ("AND", "idl"): 0x27, ("PLP", "imp"): 0x28, ("AND", "imm"): 0x29,
    ("ROL", "acc"): 0x2A, ("PLD", "imp"): 0x2B, ("BIT", "abs"): 0x2C,
    ("AND", "abs"): 0x2D, ("ROL", "abs"): 0x2E, ("AND", "abl"): 0x2F,
    ("BMI", "rel"): 0x30, ("AND", "idy"): 0x31, ("AND", "idp"): 0x32,
    ("AND", "sry"): 0x33, ("BIT", "dpx"): 0x34, ("AND", "dpx"): 0x35,
    ("ROL", "dpx"): 0x36, ("AND", "idly"): 0x37, ("SEC", "imp"): 0x38,
    ("AND", "aby"): 0x39, ("DEC", "acc"): 0x3A, ("TSC", "imp"): 0x3B,
    ("BIT", "abx"): 0x3C, ("AND", "abx"): 0x3D, ("ROL", "abx"): 0x3E,
    ("AND", "ablx"): 0x3F, ("RTI", "imp"): 0x40, ("EOR", "idx"): 0x41,
    ("WDM", "imm"): 0x42, ("EOR", "sr"): 0x43, ("MVP", "bm"): 0x44,
    ("EOR", "dp"): 0x45, ("LSR", "dp"): 0x46, ("EOR", "idl"): 0x47,
    ("PHA", "imp"): 0x48, ("EOR", "imm"): 0x49, ("LSR", "acc"): 0x4A,
    ("PHK", "imp"): 0x4B, ("JMP", "abs"): 0x4C, ("EOR", "abs"): 0x4D,
    ("LSR", "abs"): 0x4E, ("EOR", "abl"): 0x4F, ("BVC", "rel"): 0x50,
    ("EOR", "idy"): 0x51, ("EOR", "idp"): 0x52, ("EOR", "sry"): 0x53,
    ("MVN", "bm"): 0x54, ("EOR", "dpx"): 0x55, ("LSR", "dpx"): 0x56,
    ("EOR", "idly"): 0x57, ("CLI", "imp"): 0x58, ("EOR", "aby"): 0x59,
    ("PHY", "imp"): 0x5A, ("TCD", "imp"): 0x5B, ("JML", "abl"): 0x5C,
    ("EOR", "abx"): 0x5D, ("LSR", "abx"): 0x5E, ("EOR", "ablx"): 0x5F,
    ("RTS", "imp"): 0x60, ("ADC", "idx"): 0x61, ("PER", "rell"): 0x62,
    ("ADC", "sr"): 0x63, ("STZ", "dp"): 0x64, ("ADC", "dp"): 0x65,
    ("ROR", "dp"): 0x66, ("ADC", "idl"): 0x67, ("PLA", "imp"): 0x68,
    ("ADC", "imm"): 0x69, ("ROR", "acc"): 0x6A, ("RTL", "imp"): 0x6B,
    ("JMP", "ind"): 0x6C, ("ADC", "abs"): 0x6D, ("ROR", "abs"): 0x6E,
    ("ADC", "abl"): 0x6F, ("BVS", "rel"): 0x70, ("ADC", "idy"): 0x71,
    ("ADC", "idp"): 0x72, ("ADC", "sry"): 0x73, ("STZ", "dpx"): 0x74,
    ("ADC", "dpx"): 0x75, ("ROR", "dpx"): 0x76, ("ADC", "idly"): 0x77,
    ("SEI", "imp"): 0x78, ("ADC", "aby"): 0x79, ("PLY", "imp"): 0x7A,
    ("TDC", "imp"): 0x7B, ("JMP", "iax"): 0x7C, ("ADC", "abx"): 0x7D,
    ("ROR", "abx"): 0x7E, ("ADC", "ablx"): 0x7F, ("BRA", "rel"): 0x80,
    ("STA", "idx"): 0x81, ("BRL", "rell"): 0x82, ("STA", "sr"): 0x83,
    ("STY", "dp"): 0x84, ("STA", "dp"): 0x85, ("STX", "dp"): 0x86,
    ("STA", "idl"): 0x87, ("DEY", "imp"): 0x88, ("BIT", "imm"): 0x89,
    ("TXA", "imp"): 0x8A, ("PHB", "imp"): 0x8B, ("STY", "abs"): 0x8C,
    ("STA", "abs"): 0x8D, ("STX", "abs"): 0x8E, ("STA", "abl"): 0x8F,
    ("BCC", "rel"): 0x90, ("STA", "idy"): 0x91, ("STA", "idp"): 0x92,
    ("STA", "sry"): 0x93, ("STY", "dpx"): 0x94, ("STA", "dpx"): 0x95,
    ("STX", "dpy"): 0x96, ("STA", "idly"): 0x97, ("TYA", "imp"): 0x98,
    ("STA", "aby"): 0x99, ("TXS", "imp"): 0x9A, ("TXY", "imp"): 0x9B,
    ("STZ", "abs"): 0x9C, ("STA", "abx"): 0x9D, ("STZ", "abx"): 0x9E,
    ("STA", "ablx"): 0x9F, ("LDY", "imm"): 0xA0, ("LDA", "idx"): 0xA1,
    ("LDX", "imm"): 0xA2, ("LDA", "sr"): 0xA3, ("LDY", "dp"): 0xA4,
    ("LDA", "dp"): 0xA5, ("LDX", "dp"): 0xA6, ("LDA", "idl"): 0xA7,
    ("TAY", "imp"): 0xA8, ("LDA", "imm"): 0xA9, ("TAX", "imp"): 0xAA,
    ("PLB", "imp"): 0xAB, ("LDY", "abs"): 0xAC, ("LDA", "abs"): 0xAD,
    ("LDX", "abs"): 0xAE, ("LDA", "abl"): 0xAF, ("BCS", "rel"): 0xB0,
    ("LDA", "idy"): 0xB1, ("LDA", "idp"): 0xB2, ("LDA", "sry"): 0xB3,
    ("LDY", "dpx"): 0xB4, ("LDA", "dpx"): 0xB5, ("LDX", "dpy"): 0xB6,
    ("LDA", "idly"): 0xB7, ("CLV", "imp"): 0xB8, ("LDA", "aby"): 0xB9,
    ("TSX", "imp"): 0xBA, ("TYX", "imp"): 0xBB, ("LDY", "abx"): 0xBC,
    ("LDA", "abx"): 0xBD, ("LDX", "aby"): 0xBE, ("LDA", "ablx"): 0xBF,
    ("CPY", "imm"): 0xC0, ("CMP", "idx"): 0xC1, ("REP", "imm"): 0xC2,
    ("CMP", "sr"): 0xC3, ("CPY", "dp"): 0xC4, ("CMP", "dp"): 0xC5,
    ("DEC", "dp"): 0xC6, ("CMP", "idl"): 0xC7, ("INY", "imp"): 0xC8,
    ("CMP", "imm"): 0xC9, ("DEX", "imp"): 0xCA, ("WAI", "imp"): 0xCB,
    ("CPY", "abs"): 0xCC, ("CMP", "abs"): 0xCD, ("DEC", "abs"): 0xCE,
    ("CMP", "abl"): 0xCF, ("BNE", "rel"): 0xD0, ("CMP", "idy"): 0xD1,
    ("CMP", "idp"): 0xD2, ("CMP", "sry"): 0xD3, ("PEI", "dp"): 0xD4,
    ("CMP", "dpx"): 0xD5, ("DEC", "dpx"): 0xD6, ("CMP", "idly"): 0xD7,
    ("CLD", "imp"): 0xD8, ("CMP", "aby"): 0xD9, ("PHX", "imp"): 0xDA,
    ("STP", "imp"): 0xDB, ("JML", "indl"): 0xDC, ("CMP", "abx"): 0xDD,
    ("DEC", "abx"): 0xDE, ("CMP", "ablx"): 0xDF, ("CPX", "imm"): 0xE0,
    ("SBC", "idx"): 0xE1, ("SEP", "imm"): 0xE2, ("SBC", "sr"): 0xE3,
    ("CPX", "dp"): 0xE4, ("SBC", "dp"): 0xE5, ("INC", "dp"): 0xE6,
    ("SBC", "idl"): 0xE7, ("INX", "imp"): 0xE8, ("SBC", "imm"): 0xE9,
    ("NOP", "imp"): 0xEA, ("XBA", "imp"): 0xEB, ("CPX", "abs"): 0xEC,
    ("SBC", "abs"): 0xED, ("INC", "abs"): 0xEE, ("SBC", "abl"): 0xEF,
    ("BEQ", "rel"): 0xF0, ("SBC", "idy"): 0xF1, ("SBC", "idp"): 0xF2,
    ("SBC", "sry"): 0xF3, ("PEA", "abs"): 0xF4, ("SBC", "dpx"): 0xF5,
    ("INC", "dpx"): 0xF6, ("SBC", "idly"): 0xF7, ("SED", "imp"): 0xF8,
    ("SBC", "aby"): 0xF9, ("PLX", "imp"): 0xFA, ("XCE", "imp"): 0xFB,
    ("JSR", "iax"): 0xFC, ("SBC", "abx"): 0xFD, ("INC", "abx"): 0xFE,
    ("SBC", "ablx"): 0xFF,
}

_BRANCHES = {"BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ", "BRA"}


def _num(tok: str):
    """Return (value, hex_digit_count) for $hex or decimal; digit count drives width."""
    tok = tok.strip()
    if tok.startswith("$"):
        h = tok[1:]
        return int(h, 16), len(h)
    return int(tok), None


def _parse_operand(operand: str):
    """Return (mode, value, label, opbytes_or_None). label is set for symbolic refs."""
    o = operand.strip()
    if o == "" or o.upper() == "A":
        return ("acc" if o.upper() == "A" else "imp"), 0, None, 0
    # immediate
    m = re.fullmatch(r"#(\$[0-9A-Fa-f]+|\d+)", o)
    if m:
        val, digits = _num(m.group(1))
        nbytes = 2 if (digits is not None and digits > 2) or val > 0xFF else 1
        return "imm", val, None, nbytes
    # [dp] / [dp],Y / [abs]
    m = re.fullmatch(r"\[(\$[0-9A-Fa-f]+)\](,Y)?", o)
    if m:
        val, digits = _num(m.group(1))
        if digits > 4:
            return "indl", val, None, 3
        if m.group(2):
            return "idly", val, None, 1
        return "idl", val, None, 1
    # (dp) forms
    m = re.fullmatch(r"\((\$[0-9A-Fa-f]+)(,X)?\)(,Y)?", o)
    if m:
        val, digits = _num(m.group(1))
        if digits > 2:  # absolute indirect
            if m.group(2):
                return "iax", val, None, 2
            return "ind", val, None, 2
        if m.group(2):
            return "idx", val, None, 1
        if m.group(3):
            return "idy", val, None, 1
        return "idp", val, None, 1
    # ($xx,S),Y
    m = re.fullmatch(r"\((\$[0-9A-Fa-f]+),S\),Y", o)
    if m:
        return "sry", _num(m.group(1))[0], None, 1
    # $xx,S
    m = re.fullmatch(r"(\$[0-9A-Fa-f]+),S", o)
    if m:
        return "sr", _num(m.group(1))[0], None, 1
    # plain value with optional ,X / ,Y
    m = re.fullmatch(r"(\$[0-9A-Fa-f]+|\d+)(,[XY])?", o)
    if m:
        val, digits = _num(m.group(1))
        idx = m.group(2)
        width = digits if digits is not None else (6 if val > 0xFFFF else 4 if val > 0xFF else 2)
        if width <= 2:
            return ("dpx" if idx == ",X" else "dpy" if idx == ",Y" else "dp"), val, None, 1
        if width <= 4:
            return ("abx" if idx == ",X" else "aby" if idx == ",Y" else "abs"), val, None, 2
        return ("ablx" if idx == ",X" else "abl"), val, None, 3
    # otherwise a label (for branches / jumps)
    return "label", 0, o, None


def assemble(source: str, org: int):
    lines = []
    for raw in source.splitlines():
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        lines.append(line)

    # Pass 1: sizes + label addresses
    pc = org
    labels = {}
    items = []  # (kind, ...)
    for line in lines:
        if line.endswith(":"):
            labels[line[:-1]] = pc
            continue
        parts = line.split(None, 1)
        mnem = parts[0].upper()
        operand = parts[1] if len(parts) > 1 else ""
        mode, val, label, opbytes = _parse_operand(operand)
        # bare ASL/LSR/ROL/ROR/INC/DEC mean accumulator, not implied
        if mode == "imp" and (mnem, "imp") not in _TABLE and (mnem, "acc") in _TABLE:
            mode, opbytes = "acc", 0
        if mnem in _BRANCHES:
            size = 2
            items.append(("branch", mnem, label, val, pc))
        elif mnem in ("JMP", "JSR") and mode == "label":
            size = 3
            items.append(("jabs", mnem, label, pc))
        elif mnem in ("JML", "JSL") and mode == "label":
            size = 4
            items.append(("jlong", mnem, label, pc))
        else:
            if mode == "label":
                raise ValueError(f"unexpected label operand: {line}")
            size = 1 + (opbytes or 0)
            items.append(("op", mnem, mode, val, opbytes, pc))
        pc += size

    # Pass 2: emit
    out = bytearray()

    def emit_le(value, nbytes):
        for i in range(nbytes):
            out.append((value >> (8 * i)) & 0xFF)

    for item in items:
        if item[0] == "op":
            _, mnem, mode, val, opbytes, at = item
            op = _TABLE.get((mnem, mode))
            if op is None:
                raise ValueError(f"no opcode for {mnem} {mode}")
            out.append(op)
            if opbytes:
                emit_le(val, opbytes)
        elif item[0] == "branch":
            _, mnem, label, val, at = item
            out.append(_TABLE[(mnem, "rel")])
            target = labels[label] if label else val
            rel = target - (at + 2)
            if rel < -128 or rel > 127:
                raise ValueError(f"branch out of range at ${at:06X} -> {label} ({rel})")
            out.append(rel & 0xFF)
        elif item[0] == "jabs":
            _, mnem, label, at = item
            out.append(_TABLE[(mnem, "abs")])
            emit_le(labels[label] & 0xFFFF, 2)
        elif item[0] == "jlong":
            _, mnem, label, at = item
            out.append(_TABLE[(mnem, "abl")])
            emit_le(labels[label], 3)

    return bytes(out), labels


if __name__ == "__main__":
    # round-trip smoke test against the disassembler
    import importlib.util
    import pathlib

    src = """
    start:
        REP #$30
        LDA #$0000
        TCD
        LDX #$0040
    loop:
        LDA $7E4328,X
        STA [$00],Y
        AND #$01FF
        CMP $DC
        BCS skip
        ORA #$2000
    skip:
        DEX
        DEX
        BNE loop
        JSL $80A943
        RTL
    """
    code, labels = assemble(src, 0x8FCC00)
    print("bytes:", code.hex(" "))
    print("labels:", {k: f"${v:06X}" for k, v in labels.items()})

    spec = importlib.util.spec_from_file_location(
        "re65816", pathlib.Path(__file__).with_name("diagnostics") / "re65816.py")
    re = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(re)
    # write to a scratch buffer at the right file offset and disassemble
    rom = bytearray(0x100000)
    off = (0x8F & 0x7F) * 0x8000 + (0xCC00 - 0x8000)
    rom[off:off + len(code)] = code
    print("\n-- disassembly round-trip --")
    for ln in re.disassemble(bytes(rom), off, 14, m=2, x=2):
        print(ln)
