#!/usr/bin/env python3
"""Build the optional ZAMN DX Widescreen ROM hook + IPS.

Widescreen display comes from bsnes-hd ("WideScreen Mode = all scenes"); the game
only streams BG tiles for the 256px window, so bsnes-hd's extra side columns show
stale VRAM. This hook refills the columns just outside the 256px window from the
level map so the widescreen strips show correct terrain. BG streaming and OAM X
culling are display-only; the optional object-spawner relax intentionally widens
the normal map-object activation/deactivation X gate so pickups/survivors can be
created while still in the widescreen side strips.

Two hooks:
  * GATHER  - at the per-frame scroll dispatcher $80:A93F (a proven-safe, register-
              preserving trampoline). Gated to run ONCE per frame via the scheduler
              tick $20. It is INCREMENTAL: the camera moves ~2px/frame, so a new tile
              column only appears every ~4 frames. Each frame it gathers just the
              leading column(s) that scrolled in, plus a small round-robin "trickle"
              of TRICKLE columns to keep the rest fresh (covers vertical scroll and
              direction changes). On level load / warp (first frame or a >=4 tile
              jump) it does a one-frame full refill of all columns. Per-frame cost is
              therefore bounded (~leading + TRICKLE columns) no matter how wide the
              strips are. The heavy loop runs with DB=$7F so map/colbuf/scratch are
              cheap absolute accesses, and walks the map with a running +$160 row
              pointer (the row-base table $7E:4328 is exactly row*$160).
  * ENQUEUE - in vblank, at the VRAM-queue drain $80:9E7B. Cheap: appends the
              gathered colbufs to the game's own VRAM-DMA queue, marks each consumed
              ($FFFF) so it is not re-uploaded, then lets the drain DMA them and zero
              $CE so the game's "wait for queue empty" spin-waits still complete.
  * SPRITES - the OAM X-culls are widened for already-rendered actors, and the
              map-object activation/deactivation X gate is widened so object
              spawners for pickups/survivors wake up while still in the side strips.
              The render-list build also appends active type-$05 objects that are
              already in object slots but missing from $137E just outside the
              normal horizontal window.

Mesen-verified facts:
  * dispatcher entry $80:A93F (PHD; LDA #$0000; TCD ...), reached via ptr at $A93C
  * VRAM-queue drain $80:9E7B (BIT $26; BVS $9ECE; LDA $CE; ...; zeroes $CE)
  * scheduler tick   $0020 (incremented once per frame at $80:8372)
  * gameplay guards  $0E == 2 AND $0D25 != 0 (0 during level load)
  * camera           $1B6A/$1B6C ; BG1 base $1B7E (=$7800) ; thresh $DC (=$70)
  * BG1 ring origin  $1B76/$1B7A ; tilemap col/row for the camera's top-left tile
  * VRAM col table   $80:9D77[(($1B76+offset)&63)*2] ; map cell $7F:(rowbase+col*2)
  * row-base table   $7E:4328[row*2] == row*$160 (arithmetic; rowstride $B2=$0160)
  * priority         (cell&$1FF)<$DC -> OR $2000
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

# Strip columns filled per side. bsnes-hd renders a fixed number of extra columns
# per side based on its aspect setting; NSTRIP must cover that. Cost is now bounded
# by the per-frame gather budget (leading + TRICKLE), NOT by NSTRIP, so this can be
# generous. 10 (=80px/side) comfortably covers 16:9 with margin.
NSTRIP = 10
NSLOT = 2 * NSTRIP          # total strip columns (left + right)
TRICKLE = 8                 # round-robin columns refreshed per frame (vertical/reverse)
LEADCAP = 3                 # max leading columns gathered on a horizontal crossing
FULLJMP = 4                 # >= this many tiles moved in one frame -> full refill

# How far past the 256px window (in px) the OAM-build engine is allowed to draw a
# sprite, so active actors in the widescreen strips are rendered (display-only; the
# game still culls truly off-screen sprites). Matches the BG strip width.
SPRITE_MARGIN = NSTRIP * 8
OBJECT_ACTIVATION_MARGIN = SPRITE_MARGIN
TYPE05_SLOT_FIRST = 0x185E
TYPE05_SLOT_END = 0x1ADE       # one past $1ACA + $14
RENDER_ARRAY_MAX = 0x40        # $137E..$13BD, 32 object pointers

# WRAM scratch, all in free high $7F. In the gather DB=$7F so these are 4-hex ("abs")
# operands; in the enqueue DB=0 so the few it needs are written as 6-hex ("long").
COLBUF = 0xF000            # NSLOT columns * 64 bytes -> $7F:F000.. (must clear SB)
SB = 0xF500               # scratch base
CAMCOL, CAMROW, RINGCOL, RINGROW, THRESH = (SB + 2 * i for i in range(5))   # 00..08
SIDX, MC, MCX2, CSB, WRAPAT, SRCEND, WCELL = (SB + 0x0A + 2 * i for i in range(7))  # 0A..16
DCOL, DROW = SB + 0x18, SB + 0x1A
PREVSTRIDE = SB + 0x1C      # last frame's map width ($B2); change => level/map switch
FULLF = SB + 0x1E
LEADLO, LEADHI, LEADN = SB + 0x20, SB + 0x22, SB + 0x24
PREVCOL, PREVROW, REFCUR, INITDONE, LASTTICK = (SB + 0x26 + 2 * i for i in range(5))  # 26..2E
VRAMDEST = SB + 0x40      # NSLOT words ($FFFF = column skipped / already consumed)

# enqueue runs with DB=0; it reaches $7F scratch via long addressing
SIDX_L = 0x7F0000 + SIDX
VD_L = 0x7F0000 + VRAMDEST

SOURCE = f"""
; ================= GATHER (dispatcher $80:A93F, once/frame, incremental) =================
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
    LDA #$7F
    PHA
    PLB                         ; DB = $7F (scratch/colbuf/map are now abs)
    REP #$20
    LDA $00000E
    AND #$00FF
    CMP #$0002
    BEQ g_g1
    JMP g_exit
g_g1:
    LDA $000D25
    AND #$00FF
    BNE g_g2
    JMP g_exit
g_g2:
    LDA $000020                 ; scheduler frame tick
    CMP ${LASTTICK:04X}
    BNE g_run
    JMP g_exit                  ; already gathered this frame
g_run:
    STA ${LASTTICK:04X}
    ; --- read inputs ---
    LDA $001B6A
    LSR
    LSR
    LSR
    STA ${CAMCOL:04X}
    LDA $001B6C
    LSR
    LSR
    LSR
    STA ${CAMROW:04X}
    LDA $001B76
    STA ${RINGCOL:04X}
    LDA $001B7A
    STA ${RINGROW:04X}
    LDA $0000DC
    STA ${THRESH:04X}
    ; --- keep REFCUR sane (first-run garbage guard) ---
    LDA ${REFCUR:04X}
    CMP #${NSLOT:04X}
    BCC g_refok
    LDA #$0000
    STA ${REFCUR:04X}
g_refok:
    ; --- deltas ---
    LDA ${CAMCOL:04X}
    SEC
    SBC ${PREVCOL:04X}
    STA ${DCOL:04X}
    LDA ${CAMROW:04X}
    SEC
    SBC ${PREVROW:04X}
    STA ${DROW:04X}
    ; --- decide full vs incremental ---
    LDA $0000B2                 ; map width changed => new level/map => full refill
    CMP ${PREVSTRIDE:04X}
    BNE g_full
    LDA ${INITDONE:04X}
    CMP #$0001
    BNE g_full
    LDA ${DCOL:04X}
    BPL g_dcp
    EOR #$FFFF
    INC
g_dcp:
    CMP #${FULLJMP:04X}
    BCS g_full
    LDA ${DROW:04X}
    BPL g_drp
    EOR #$FFFF
    INC
g_drp:
    CMP #${FULLJMP:04X}
    BCS g_full
    BRA g_incr
g_full:
    LDA #$0001
    STA ${FULLF:04X}
    STA ${INITDONE:04X}
    LDA #$0000
    STA ${REFCUR:04X}
    BRA g_iter
g_incr:
    LDA #$0000
    STA ${FULLF:04X}
    ; leading-column window from DCOL
    LDA ${DCOL:04X}
    BNE g_ld_nz
    LDA #$7FFF                  ; DCOL==0: empty window
    STA ${LEADLO:04X}
    LDA #$8000
    STA ${LEADHI:04X}
    BRA g_iter
g_ld_nz:
    BMI g_ld_neg
    CMP #${LEADCAP:04X}         ; right: LEADN = min(DCOL, LEADCAP)
    BCC g_ld_pn
    LDA #${LEADCAP:04X}
g_ld_pn:
    STA ${LEADN:04X}
    LDA #${NSLOT:04X}           ; LEADLO = NSLOT - LEADN ; LEADHI = NSLOT-1
    SEC
    SBC ${LEADN:04X}
    STA ${LEADLO:04X}
    LDA #${NSLOT - 1:04X}
    STA ${LEADHI:04X}
    BRA g_iter
g_ld_neg:
    EOR #$FFFF                  ; |DCOL|
    INC
    CMP #${LEADCAP:04X}
    BCC g_ld_nn
    LDA #${LEADCAP:04X}
g_ld_nn:
    STA ${LEADN:04X}
    LDA #$0000                  ; left: LEADLO = 0 ; LEADHI = LEADN-1
    STA ${LEADLO:04X}
    LDA ${LEADN:04X}
    DEC
    STA ${LEADHI:04X}
g_iter:
    LDA #$0000
    STA ${SIDX:04X}
g_each:
    LDA ${FULLF:04X}
    BNE g_do
    LDA ${SIDX:04X}             ; leading? LEADLO <= SIDX <= LEADHI
    CMP ${LEADLO:04X}
    BCC g_trk
    LDA ${LEADHI:04X}
    CMP ${SIDX:04X}
    BCS g_do
g_trk:
    LDA ${SIDX:04X}             ; trickle? (SIDX-REFCUR) mod NSLOT < TRICKLE
    SEC
    SBC ${REFCUR:04X}
    BPL g_trk2
    CLC
    ADC #${NSLOT:04X}
g_trk2:
    CMP #${TRICKLE:04X}
    BCC g_do
    JMP g_skip
g_do:
    JSR g_slot
g_skip:
    LDA ${SIDX:04X}
    INC
    STA ${SIDX:04X}
    CMP #${NSLOT:04X}
    BCS g_after
    JMP g_each
g_after:
    LDA ${FULLF:04X}
    BNE g_noadv
    LDA ${REFCUR:04X}           ; REFCUR = (REFCUR + TRICKLE) mod NSLOT
    CLC
    ADC #${TRICKLE:04X}
    CMP #${NSLOT:04X}
    BCC g_radv
    SEC
    SBC #${NSLOT:04X}
g_radv:
    STA ${REFCUR:04X}
g_noadv:
    LDA ${CAMCOL:04X}
    STA ${PREVCOL:04X}
    LDA ${CAMROW:04X}
    STA ${PREVROW:04X}
    LDA $0000B2
    STA ${PREVSTRIDE:04X}
g_exit:
    REP #$30
    PLY
    PLX
    PLA
    PLD
    PLB
    PLP
    RTL

; ---- gather one strip column (slot index in SIDX); DB=$7F ----
g_slot:
    LDA ${SIDX:04X}
    CMP #${NSTRIP:04X}
    BCC g_s_left
    CLC
    ADC #${32 - NSTRIP:04X}     ; right strip cols +32..
    BRA g_s_have
g_s_left:
    SEC
    SBC #${NSTRIP:04X}          ; left strip cols -NSTRIP..-1
g_s_have:
    CLC
    ADC ${CAMCOL:04X}
    STA ${MC:04X}
    BMI g_s_skip                ; off the left edge
    ASL
    STA ${MCX2:04X}
    CMP $0000B2                 ; row stride in bytes == map width * 2
    BCC g_s_ok
g_s_skip:
    LDA ${SIDX:04X}
    ASL
    TAX
    LDA #$FFFF
    STA ${VRAMDEST:04X},X       ; mark slot skipped
    RTS
g_s_ok:
    LDA ${SIDX:04X}             ; CSB = SIDX*64 (colbuf base for this slot)
    ASL
    ASL
    ASL
    ASL
    ASL
    ASL
    STA ${CSB:04X}
    CLC
    ADC #$0040
    STA ${WRAPAT:04X}           ; WRAPAT = CSB + 64
    LDA ${RINGROW:04X}          ; Y = CSB + (RINGROW&31)*2  (ring write start)
    AND #$001F
    ASL
    CLC
    ADC ${CSB:04X}
    TAY
    LDA ${CAMROW:04X}           ; X = rowbase[CAMROW] + MC*2  (map source)
    ASL
    TAX
    LDA $7E4328,X
    CLC
    ADC ${MCX2:04X}
    STA ${SRCEND:04X}           ; (temp) start = rowbase[CAMROW] + MC*2
    TAX                         ; X = map source pointer
    LDA $0000B2                 ; SRCEND = start + 32*stride (live map width $B2)
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC ${SRCEND:04X}
    STA ${SRCEND:04X}
g_row:
    LDA $0000,X                 ; map cell (DB=$7F -> $7F:X)
    STA ${WCELL:04X}
    AND #$01FF
    CMP ${THRESH:04X}
    LDA ${WCELL:04X}
    BCS g_np
    ORA #$2000                  ; priority bit
g_np:
    STA ${COLBUF:04X},Y         ; colbuf[CSB + ring offset]
    INY
    INY
    CPY ${WRAPAT:04X}
    BNE g_nw
    TYA                         ; wrap ring write back to column start
    SEC
    SBC #$0040
    TAY
g_nw:
    TXA                         ; advance map source by one row (live stride $B2)
    CLC
    ADC $0000B2
    TAX
    CPX ${SRCEND:04X}
    BNE g_row
    ; VRAMDEST[slot] = bgbase + $80:9D77[((RINGCOL + off)&63)*2]
    LDA ${MC:04X}
    SEC
    SBC ${CAMCOL:04X}
    CLC
    ADC ${RINGCOL:04X}
    AND #$003F
    ASL
    TAX
    LDA $809D77,X
    CLC
    ADC $001B7E
    PHA
    LDA ${SIDX:04X}
    ASL
    TAX
    PLA
    STA ${VRAMDEST:04X},X
    RTS

disp_stub:
    PHD
    LDA #$0000
    JML $80A943

; ================= ENQUEUE (VRAM drain $80:9E7B); DB=0 =================
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
    PLB                         ; DB = 0
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
    STA ${SIDX_L:06X}
e_loop:
    LDA ${SIDX_L:06X}
    ASL
    TAX
    LDA ${VD_L:06X},X
    CMP #$FFFF
    BEQ e_next
    PHA
    LDX $CE
    CPX #$002E
    BCC e_room
    PLA
    BRA e_done
e_room:
    LDA ${SIDX_L:06X}
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
    LDA ${SIDX_L:06X}           ; consume: VRAMDEST[slot] = $FFFF
    ASL
    TAX
    LDA #$FFFF
    STA ${VD_L:06X},X
e_next:
    LDA ${SIDX_L:06X}
    INC
    STA ${SIDX_L:06X}
    CMP #${NSLOT:04X}
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

; ================= TYPE-$05 RENDER-LIST RELAX (items/survivors) =================
; Replaces the stock pair JSR $BCE2 / JSR $BC23 with one long helper. It rebuilds
; $137E like stock, then appends active type-$05 slots that are horizontally within
; the widescreen margin but were not linked through $1B5E. Finally it performs the
; stock OAM-shadow clear from $BC23. This is display-only: $1B5E and actor state are
; untouched; only the current frame's flattened render array can grow.
ws_build_render_list:
    LDY #$0000
    LDX $1B5E
    BEQ wbr_scan
wbr_loop:
    LDA $00,X
    BPL wbr_next
    ASL
    BMI wbr_add
    LDA $02,X
    SEC
    SBC $1B6A
    CMP #$FF80
    BCS wbr_ycheck
    CMP #$0180
    BCS wbr_next
wbr_ycheck:
    LDA $06,X
    SEC
    SBC $1B6C
    CMP #$FF80
    BCS wbr_add
    CMP #$0180
    BCS wbr_next
wbr_add:
    TXA
    STA $137E,Y
    INY
    INY
wbr_next:
    LDA $12,X
    TAX
    BNE wbr_loop

wbr_scan:
    LDX #${TYPE05_SLOT_FIRST:04X}
wbr_sloop:
    LDA $0E,X
    CMP #$0005
    BNE wbr_snext
    LDA $00,X
    BPL wbr_snext                ; inactive/free: do not resurrect stale slots
    ASL
    BMI wbr_dupcheck             ; screen-anchored / forced-visible object
    LDA $02,X
    SEC
    SBC $1B6A
    CMP #${(0x10000 - SPRITE_MARGIN) & 0xFFFF:04X}
    BCS wbr_sycheck              ; left strip [-margin..-1]
    CMP #${0x0100 + SPRITE_MARGIN:04X}
    BCS wbr_snext                ; far right
wbr_sycheck:
    LDA $06,X
    SEC
    SBC $1B6C
    CMP #$FF80
    BCS wbr_dupcheck
    CMP #$0180
    BCS wbr_snext
wbr_dupcheck:
    STX $38                      ; candidate slot
    STY $3A                      ; current render-byte count
    LDY #$0000
wbr_dloop:
    CPY $3A
    BEQ wbr_append
    LDA $137E,Y
    CMP $38
    BEQ wbr_restore
    INY
    INY
    BRA wbr_dloop
wbr_append:
    LDY $3A
    CPY #${RENDER_ARRAY_MAX:04X}
    BCS wbr_restore
    LDA $38
    STA $137E,Y
    INY
    INY
    STY $3A
wbr_restore:
    LDY $3A
wbr_snext:
    TXA
    CLC
    ADC #$0014
    TAX
    CPX #${TYPE05_SLOT_END:04X}
    BCC wbr_sloop
    STY $9C

    ; Stock $80:BC23 OAM-shadow clear.
    PHD
    LDA #$13BE
    TCD
    LDX #$0008
    SEP #$10
    LDY #$E0
    CLC
wbr_clear_loop:
    STY $01
    STY $05
    STY $09
    STY $0D
    STY $11
    STY $15
    STY $19
    STY $1D
    STY $21
    STY $25
    STY $29
    STY $2D
    STY $31
    STY $35
    STY $39
    STY $3D
    TDC
    ADC #$0040
    TCD
    DEX
    BNE wbr_clear_loop
    LDA #$AAAA
    STA $00
    STA $02
    STA $04
    STA $06
    STA $08
    STA $0A
    STA $0C
    STA $0E
    STA $10
    STA $12
    STA $14
    STA $16
    STA $18
    STA $1A
    STA $1C
    STA $1E
    REP #$30
    PLD
    RTL

; ================= SPRITE X-CULL RELAX (widescreen strips) =================
; Replaces the OAM-build engine's X-cull range test (4 sites). Called via JSL with
; A = sprite screen-X (16-bit), in the engine's M=16 state. Returns:
;   carry SET   -> cull this sprite (truly off-screen past the strips)
;   carry CLEAR -> draw; A=0 (Z=1) on-screen no high bit, A=1 (Z=0) strip -> set high
; Each call site keeps its own original "set X-high" bytes (ORA vs EOR), run only when
; A!=0, so a strip sprite (X>=256 or X<0) gets its X-high bit and bsnes-hd renders it
; in the strip. Display-only: the helper touches no memory; sites touch only OAM.
ws_sprite_cull:
    CMP #$0100
    BCC wsc_nohigh              ; [0,255] on-screen, no high bit
    CMP #${256 + SPRITE_MARGIN + 1:04X}
    BCC wsc_high                ; right strip [256 .. 255+margin]
    CMP #${(0x10000 - SPRITE_MARGIN) & 0xFFFF:04X}
    BCC wsc_cull                ; truly off-screen -> cull
wsc_high:                       ; right strip, or left strip [-margin..-1]
    CLC
    LDA #$0001
    RTL
wsc_nohigh:
    CLC
    LDA #$0000
    RTL
wsc_cull:
    SEC
    RTL
"""


def main() -> int:
    code, labels = asm.assemble(SOURCE, ORG)
    limit = 0x700  # spare region $8F:CC00..$8F:D2FF
    if len(code) > limit:
        raise SystemExit(f"routine too large: {len(code)} bytes > {limit} free")

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

    # Replace JSR $BCE2 / JSR $BC23 in the sprite engine with one long helper that
    # rebuilds the normal render list, appends widened type-$05 entries, and clears OAM.
    render_pair_off = 0x3D2A  # $80:BD2A
    orig = bytes(rom[render_pair_off:render_pair_off + 6])
    if orig != bytes.fromhex("20 E2 BC 20 23 BC"):
        raise SystemExit(f"unexpected render-list call pair at 0x{render_pair_off:05X}: {orig.hex(' ')}")
    helper = labels["ws_build_render_list"]
    rom[render_pair_off:render_pair_off + 6] = bytes([
        0x22, helper & 0xFF, (helper >> 8) & 0xFF, (helper >> 16) & 0xFF,
        0xEA, 0xEA])

    # Map-object activation uses an X/Y distance gate around the camera center:
    # abs(objX - (camX+$80)) < $0090, abs(objY - (camY+$70)) < $0090.
    # The stock X range wakes map-object spawners at about screen X [-15,271],
    # so pickups/survivors can still pop at the 4:3 edge. Widen only the X gate
    # by the strip margin; leave Y unchanged because this widescreen pass adds
    # horizontal view only.
    object_x_gate_off = 0x4948  # $80:C948  CMP #$0090 / BCS outside
    orig = bytes(rom[object_x_gate_off:object_x_gate_off + 5])
    if orig != bytes.fromhex("C9 90 00 B0 1C"):
        raise SystemExit(f"unexpected object X-gate bytes at 0x{object_x_gate_off:05X}: {orig.hex(' ')}")
    object_threshold = 0x0090 + OBJECT_ACTIVATION_MARGIN
    if object_threshold > 0xFFFF:
        raise SystemExit(f"object activation threshold too large: 0x{object_threshold:04X}")
    rom[object_x_gate_off + 1:object_x_gate_off + 3] = object_threshold.to_bytes(2, "little")

    # The map-object scanner is a cooperative task and stock only runs the proximity
    # pass when ($20 & 3) == 0. With a wider leading edge, that cadence can still let
    # old/mid-cycle states pop an object at the 4:3 edge before the next pass reaches
    # it. Keep the task's yield points, but remove the tick modulo so each wake can
    # perform the widened proximity pass.
    object_scan_cadence_off = 0x4918  # $80:C918  LDA $20 / AND #$0003 / BNE $C90A
    orig = bytes(rom[object_scan_cadence_off:object_scan_cadence_off + 8])
    if orig != bytes.fromhex("AD 20 00 29 03 00 D0 EA"):
        raise SystemExit(f"unexpected object scan cadence bytes at 0x{object_scan_cadence_off:05X}: {orig.hex(' ')}")
    rom[object_scan_cadence_off + 4:object_scan_cadence_off + 6] = b"\x00\x00"

    # --- sprite X-cull relax: route the 4 OAM-build cull sites through ws_sprite_cull ---
    # Original 22 bytes: CMP #$0100 / BCC draw / CMP #$FFF1 / BCC cull / set-X-high(12).
    # New 22 bytes, keeping each site's own set-high (sites 1-3 ORA, site 4 EOR):
    #   JSL ws_sprite_cull ; BCS cull ; BEQ draw(+$0E) ; <original set-high 12B> ; NOP NOP
    helper = labels["ws_sprite_cull"]
    # (file_off, snes_addr, cull_target) for the four sites
    sprite_sites = [
        (0x3A74, 0xBA74, 0xBAAB),
        (0x3AE4, 0xBAE4, 0xBB1E),
        (0x3B5A, 0xBB5A, 0xBB94),
        (0x3BD7, 0xBBD7, 0xBC11),
    ]
    for foff, snes, cull in sprite_sites:
        orig = bytes(rom[foff:foff + 22])
        set_high = orig[10:22]   # LDY $B747,X / LDA $B749,X / (ORA|EOR) $13BE,Y / STA $13BE,Y
        ok = (orig[0:5] == bytes.fromhex("C900019011")          # CMP #$0100 / BCC draw
              and orig[5:9] == bytes.fromhex("C9F1FF90")        # CMP #$FFF1 / BCC ... (operand varies)
              and set_high[0:6] == bytes.fromhex("BC47B7BD49B7")
              and set_high[6] in (0x19, 0x59)                   # ORA or EOR $13BE,Y
              and set_high[7:12] == bytes.fromhex("BE1399BE13"))
        if not ok:
            raise SystemExit(f"unexpected sprite-cull bytes at 0x{foff:05X}: {orig.hex(' ')}")
        rel = cull - (snes + 6)        # BCS operand at snes+4, measured from snes+6
        if not 0 <= rel <= 0x7F:
            raise SystemExit(f"sprite-cull BCS out of range at 0x{foff:05X}: {rel}")
        new = bytes([0x22, helper & 0xFF, (helper >> 8) & 0xFF, (helper >> 16) & 0xFF,
                     0xB0, rel, 0xF0, 0x0E]) + set_high + b"\xEA\xEA"
        assert len(new) == 22
        rom[foff:foff + 22] = new

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

    print(f"routine bytes : {len(code)} (at $8F:CC00, {limit - len(code)} free)")
    print(f"strip columns : {NSTRIP}/side ({NSLOT} total); trickle {TRICKLE}/frame; colbuf ${COLBUF:04X}")
    print(f"gather_entry  : ${labels['gather_entry']:06X}")
    print(f"g_slot        : ${labels['g_slot']:06X}")
    print(f"enqueue_entry : ${labels['enqueue_entry']:06X}")
    print(f"ws_sprite_cull: ${labels['ws_sprite_cull']:06X}  (4 cull sites, margin {SPRITE_MARGIN}px)")
    print(f"object X gate : $80:C948  threshold ${object_threshold:04X} (stock $0090)")
    print("object scanner: $80:C91C  every wake (stock every 4 ticks)")
    print(f"test ROM      : {out_rom}")
    print(f"widescreen IPS: {out_ips} ({len(ips)} bytes)")
    print(f"SHA-256       : {build.digest(bytes(rom), 'sha256')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
