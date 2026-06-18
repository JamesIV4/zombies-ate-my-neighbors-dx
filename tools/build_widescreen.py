#!/usr/bin/env python3
"""Build the optional ZAMN DX Widescreen ROM hook + IPS.

Widescreen display comes from bsnes-hd ("WideScreen Mode = all scenes"); the game
only streams BG tiles for the 256px window, so bsnes-hd's extra side columns show
stale VRAM. This hook refills the columns just outside the 256px window from the
level map so the widescreen strips show correct terrain. Display-only: it touches
the BG tilemap VRAM queue and a scratch buffer, never actor/AI state, so enemy
spawning and aggro are unchanged.

Two hooks:
  * GATHER  - at the per-frame scroll dispatcher $80:A93F (a proven-safe, register-
              preserving trampoline). The dispatcher is called many times per frame
              (1px camera step each), so the gather is gated to run ONCE per frame
              via the scheduler tick $20. It builds the 8 strip columns into colbufs
              in free $7F and records each column's VRAM destination. No queue here.
  * ENQUEUE - in vblank, at the VRAM-queue drain $80:9E7B. Cheap: appends the
              pre-gathered colbufs to the game's own VRAM-DMA queue, then lets the
              drain DMA them and zero $CE so the game's "wait for queue empty"
              spin-waits ($80:8372 scheduler, $80:A545 load) still complete.

Mesen-verified facts:
  * dispatcher entry $80:A93F (PHD; LDA #$0000; TCD ...), reached via ptr at $A93C
  * VRAM-queue drain $80:9E7B (BIT $26; BVS $9ECE; LDA $CE; ...; zeroes $CE)
  * scheduler tick   $0020 (incremented once per frame at $80:8372)
  * gameplay guards  $0E == 2 AND $0D25 != 0 (0 during level load)
  * camera           $1B6A/$1B6C ; BG1 base $1B7E (=$7800) ; thresh $DC (=$70)
  * BG1 ring origin  $1B76/$1B7A ; tilemap col/row for the camera's top-left tile
  * VRAM col table   $80:9D77[(($1B76+offset)&63)*2] ; map cell
                     $7F:(rowbase+col*2), rowbase=$7E:4328[row*2] ;
                     priority (cell&$1FF)<$DC -> OR $2000
  * queue            src $1B84/bank $1BB4/vram $1BE4/vmain $1C14/size $1C44, len $CE
  * free WRAM        map ends ~$7F:8F00, so $7F:F000+ is free (mailbox $FFF0)
"""
from __future__ import annotations

import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


asm = _load("asm65816", TOOLS / "asm65816.py")
build = _load("build", TOOLS / "build.py")

ORG = 0x8FCC00
DISP_HOOK_FILE = 0x293F    # $80:A93F  PHD;LDA #$0000  (dispatcher entry)
DRAIN_HOOK_FILE = 0x1E7B   # $80:9E7B  BIT $26;BVS $9ECE  (VRAM-queue drain)
ROUTINE_FILE = (0x8F & 0x7F) * 0x8000 + (0xCC00 - 0x8000)  # 0x7CC00

COLBUF = 0xFDC0            # 8 columns * 64 bytes -> $7F:FDC0-$FFBF
S = 0x7FFFC0
CAMCOL, CAMROW, SIDX, MC, MCX2, BUFOFF, WROW, WCELL = (S + 2 * i for i in range(8))
VRAMDEST = 0x7FFFD0        # 8 words, $FFFF = column skipped
LASTTICK = 0x7FFFE0        # last scheduler tick we gathered on

SOURCE = f"""
; ============ GATHER (dispatcher $80:A93F, gated once per frame) ============
gather_entry:
    JSL disp_stub               ; run the original per-frame scroll dispatcher
    PHP
    PHB
    PHD
    REP #$30
    PHA                         ; preserve dispatcher's A/X/Y return state
    PHX
    PHY
    LDA #$0000
    TCD                         ; DP = 0
    SEP #$20
    LDA #$00
    PHA
    PLB                         ; DB = 0
    LDA $0E
    CMP #$02
    BNE g_bail
    LDA $0D25
    BNE g_chk
g_bail:
    JMP g_exit
g_chk:
    REP #$20
    LDA $20                     ; scheduler frame tick
    CMP ${LASTTICK:06X}
    BNE g_run
    JMP g_exit                  ; already gathered this frame
g_run:
    STA ${LASTTICK:06X}
    LDA $1B6A
    LSR
    LSR
    LSR
    STA ${CAMCOL:06X}
    LDA $1B6C
    LSR
    LSR
    LSR
    STA ${CAMROW:06X}
    LDA #$0000
    STA ${SIDX:06X}
g_col:
    LDA ${SIDX:06X}
    CMP #$0004
    BCC g_left
    CLC
    ADC #$001C                  ; right strip cols +32..+35
    BRA g_have
g_left:
    SEC
    SBC #$0004                  ; left strip cols -4..-1
g_have:
    CLC
    ADC ${CAMCOL:06X}
    STA ${MC:06X}
    LDA ${MC:06X}
    BMI g_skip                  ; off the left edge
    ASL
    CMP $B2                     ; row stride in bytes == map width * 2
    BCC g_mc_ok
g_skip:
    LDA #$FFFF                  ; off the map edge -> mark slot skipped
    PHA
    LDA ${SIDX:06X}
    ASL
    TAX
    PLA
    STA ${VRAMDEST:06X},X
    JMP g_next
g_mc_ok:
    STA ${MCX2:06X}
    LDA ${SIDX:06X}
    ASL
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #${COLBUF:04X}
    STA ${BUFOFF:06X}
    LDA ${CAMROW:06X}
    STA ${WROW:06X}
    LDY #$0020
g_row:
    LDA ${WROW:06X}
    ASL
    TAX
    LDA $7E4328,X
    CLC
    ADC ${MCX2:06X}
    TAX
    LDA $7F0000,X
    STA ${WCELL:06X}
    AND #$01FF
    CMP $DC
    LDA ${WCELL:06X}
    BCS g_no_pri
    ORA #$2000
g_no_pri:
    PHA
    LDA ${WROW:06X}
    SEC
    SBC ${CAMROW:06X}
    CLC
    ADC $1B7A                   ; BG1 tilemap row at camera top
    AND #$001F
    ASL
    CLC
    ADC ${BUFOFF:06X}
    TAX
    PLA
    STA $7F0000,X
    LDA ${WROW:06X}
    INC
    STA ${WROW:06X}
    DEY
    BNE g_row
    LDA ${MC:06X}
    SEC
    SBC ${CAMCOL:06X}
    CLC
    ADC $1B76                   ; BG1 tilemap col at camera left
    AND #$003F
    ASL
    TAX
    LDA $809D77,X
    CLC
    ADC $1B7E
    PHA
    LDA ${SIDX:06X}
    ASL
    TAX
    PLA
    STA ${VRAMDEST:06X},X
g_next:
    LDA ${SIDX:06X}
    INC
    STA ${SIDX:06X}
    CMP #$0008
    BCS g_exit
    JMP g_col
g_exit:
    REP #$30
    PLY
    PLX
    PLA
    PLD
    PLB
    PLP
    RTL

disp_stub:
    PHD
    LDA #$0000
    JML $80A943

; ============ ENQUEUE (VRAM drain $80:9E7B) ============
enqueue_entry:
    PHP
    PHB
    PHD
    REP #$30
    LDA #$0000
    TCD
    SEP #$20
    LDA #$00
    PHA
    PLB
    LDA $0E
    CMP #$02
    BNE e_bail
    LDA $0D25
    BNE e_run
e_bail:
    JMP e_exit
e_run:
    REP #$20
    LDA #$0000
    STA ${SIDX:06X}
e_loop:
    LDA ${SIDX:06X}
    ASL
    TAX
    LDA ${VRAMDEST:06X},X
    CMP #$FFFF
    BEQ e_next
    PHA
    LDX $CE
    CPX #$002E
    BCC e_room
    PLA
    BRA e_done
e_room:
    LDA ${SIDX:06X}
    ASL
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #${COLBUF:04X}
    STA $1B84,X
    LDA #$007F
    STA $1BB4,X
    PLA
    STA $1BE4,X
    LDA #$0081
    STA $1C14,X
    LDA #$0040
    STA $1C44,X
    INX
    INX
    STX $CE
e_next:
    LDA ${SIDX:06X}
    INC
    STA ${SIDX:06X}
    CMP #$0008
    BCC e_loop
e_done:
    LDA $26
    BMI e_exit
    LDA $CE
    BEQ e_exit
    LDA #$8000
    STA $26
e_exit:
    REP #$30
    PLD
    PLB
    PLP
    BIT $26
    BVS e_drain_skip
    JML $809E7F
e_drain_skip:
    JML $809ECE
"""


def main() -> int:
    code, labels = asm.assemble(SOURCE, ORG)
    if len(code) > 0x700:
        raise SystemExit(f"routine too large: {len(code)} bytes > free space")

    base = (ROOT / build.DEFAULT_ROM).read_bytes()
    rom = build.patch_rom(base)

    def patch(file_off, expect_hex, target_addr):
        orig = bytes(rom[file_off:file_off + 4])
        if orig != bytes.fromhex(expect_hex):
            raise SystemExit(f"unexpected bytes at 0x{file_off:06X}: {orig.hex(' ')}")
        rom[file_off:file_off + 4] = bytes([
            0x5C, target_addr & 0xFF, (target_addr >> 8) & 0xFF,
            (target_addr >> 16) & 0xFF])

    patch(DISP_HOOK_FILE, "0B A9 00 00", labels["gather_entry"])
    patch(DRAIN_HOOK_FILE, "24 26 70 4F", labels["enqueue_entry"])
    rom[ROUTINE_FILE:ROUTINE_FILE + len(code)] = code

    checksum = sum(rom) & 0xFFFF
    co = build.CHECKSUM_OFFSET
    rom[co:co + 2] = (checksum ^ 0xFFFF).to_bytes(2, "little")
    rom[co + 2:co + 4] = checksum.to_bytes(2, "little")

    dx = build.patch_rom(base)
    ips = build.make_ips(bytes(dx), bytes(rom))

    out_rom = ROOT / "dist" / "Zombies Ate My Neighbors DX Widescreen.sfc"
    out_ips = ROOT / "mod" / "widescreen.ips"
    out_rom.parent.mkdir(parents=True, exist_ok=True)
    out_ips.parent.mkdir(parents=True, exist_ok=True)
    out_rom.write_bytes(rom)
    out_ips.write_bytes(ips)

    print(f"routine bytes : {len(code)} (at $8F:CC00, {0x700 - len(code)} free)")
    print(f"gather_entry  : ${labels['gather_entry']:06X}")
    print(f"enqueue_entry : ${labels['enqueue_entry']:06X}")
    print(f"test ROM      : {out_rom}")
    print(f"widescreen IPS: {out_ips} ({len(ips)} bytes)")
    print(f"SHA-256       : {build.digest(bytes(rom), 'sha256')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
