# Widescreen (optional feature) — plan & progress

Status: **BG strip-fill ROM hook is stable in-game and data-correct in Mesen**
(runs identical to stock DX, full scrolling, no crash/hang; `mesen_ws_verify.lua`
passes with `failures=0`). Visual confirmation in bsnes-hd is still the next check.
This doc captures the design, the reverse-engineering, the bugs fixed, and what's
left.

---

## 1. Goal

Add an **optional** widescreen mode that shows more of the level horizontally,
**without changing gameplay** — specifically without letting enemies activate or
aggro on neighbors earlier than they normally would. Ideally it auto-matches the
player's monitor aspect ratio.

## 2. Why this is hard (the core constraint)

The SNES PPU emits exactly **256 px per scanline**. A ROM hack alone cannot widen
the field of view — the extra pixels have to come from a renderer that fetches more
background and sprites. So widescreen has two parts:

1. **A renderer that draws past 256 px.** The only SNES option is **bsnes-hd**
   (`WideScreen Mode = all scenes`). It renders extra BG/sprite columns on each side.
2. **Correct content in those extra columns.** bsnes-hd reads VRAM; the game only
   streams BG tiles for the 256 px window, so the widescreen strips show **stale
   VRAM** (garbage on the leading edge). A small **ROM hack** must keep those strip
   columns filled from the level map.

This is **display-only**: bsnes-hd renders more of the world the game already
simulates; it does not change the game's camera, AI, spawning, or aggro. Our ROM
hook only writes to the BG tilemap VRAM queue + a scratch buffer — never actor/AI
state — so the no-gameplay-change requirement holds by construction.

### POC result (user, in standalone bsnes-hd)
Loading **unpatched** ZAMN in bsnes-hd with widescreen + "render sprites anywhere":
- **Sprites:** render correctly in the strips. (The game culls them at the 256 edge;
  a later OAM-cull relax can show active sprites in the strips.)
- **HUD:** stays correctly in the 4:3 inner region. No work needed.
- **Background:** the one real problem — the leading strip shows stale tiles. **This
  is what the ROM hook fixes.**

## 3. Emulator hosting (open question, deferred)

We currently run the mod in **BizHawk** (its Lua drives the analog/aim runtime).
BizHawk **cannot host bsnes-hd cleanly** — three independent walls:
1. its libretro host forces core options to defaults (can't enable widescreen),
2. it has no command-line way to load a libretro core,
3. its libretro video/memory support is experimental.

So for now the user tests the ROM in **standalone bsnes-hd**. Shipping widescreen in
the launcher will require either a custom-default bsnes-hd libretro core + patched
BizHawk loader, or another hosting approach. **The ROM hook is independent of this**
and is the long pole, so it's being built first.

---

## 4. How the ROM hook works

bsnes-hd renders the strips; our hook keeps the BG1 tilemap's strip columns fresh.
Every frame it reads the level map for the **4 columns just outside the 256 px window
on each side**, builds them into scratch buffers, and feeds them to the game's own
VRAM-DMA queue so they upload in vblank.

### Two hooks

| Hook | Site | Context | Job |
|---|---|---|---|
| **GATHER** | `$80:A93F` (scroll dispatcher entry, via trampoline) | active display, **gated once/frame** | Re-run the original dispatcher, then build the 8 strip columns into colbufs and record each column's VRAM destination. No queue. |
| **ENQUEUE** | `$80:9E7B` (VRAM-queue drain entry, via trampoline) | vblank, cheap | Append the pre-gathered colbufs to the game's VRAM-DMA queue, set the dirty flag, then continue the original drain (which DMAs them and zeroes `$CE`). |

The split exists because the **gather is heavy** (8 cols × 32 rows) and must stay out
of vblank, while VRAM uploads must happen **in** vblank. The dispatcher is called many
times per frame (1 px camera step each) and is NMI-driven, so the gather is gated to
run **once per frame** using the scheduler tick `$20`.

### Routine + memory layout

Routine lives in free ROM at **`$8F:CC00`** (1792 free bytes). Scratch lives in free
high WRAM (the level map ends ~`$7F:8F00`, so `$7F:F000+` is free; the DX mailbox at
`$7F:FFF0` is already proven free):

```
$7F:FDC0-$FFBF   colbuf      8 columns × 64 bytes (32 tiles each)
$7F:FFC0-$FFCF   scratch     CAMCOL CAMROW SIDX MC MCX2 BUFOFF WROW WCELL
$7F:FFD0-$FFDF   VRAMDEST    8 words ($FFFF = column skipped at level edge)
$7F:FFE0         LASTTICK    last scheduler tick we gathered on
$7F:FFF0-$FFF9   (DX analog mailbox)
```

### Per-column pipeline
For strip column offset `off` (`-4..-1` and `+32..+35`) and world-col
`mc = camera_col + off`:
1. **gather:** for each of 32 rows, `cell = $7F:( rowbase[row] + mc*2 )` where
   `rowbase = $7E:4328[row*2]`; apply priority `(cell & $1FF) < $DC → OR $2000`;
   store to `colbuf[ ($1B7A + row_offset) & 31 ]` (the BG1 tilemap ring row).
2. **dest:** `VRAMDEST = $1B7E + $80:9D77[(($1B76 + off) & 63)*2]`.
3. **enqueue (vblank):** queue entry `src=colbuf, bank=$7F, vram=VRAMDEST,
   vmain=$0081 (vertical +32), size=$0040`.

---

## 5. Reverse-engineered facts (Mesen-verified live where noted)

| Thing | Value |
|---|---|
| Level map | `$7F:0000-$8EFF`, contiguous; `cell(col,row) = $7F:( rowbase + col*2 )` |
| Row-base table | `$7E:4328[row*2]` → row's start in `$7F` |
| Map width / rowstride `$B2` | `$0160` = 176 tiles wide (live) |
| BG1 tilemap base `$1B7E` | `$7800` (live), 64×32 (two 32-col quadrants) |
| BG1 ring origin | `$1B76` = tilemap col at camera left; `$1B7A` = tilemap row at camera top |
| VRAM column table | `$80:9D77[ colidx*2 ]`, `colidx = ($1B76 + strip_offset) & 63` |
| Priority threshold `$DC` | `$70` (live); `(cell & $1FF) < $DC → set $2000` |
| VRAM-DMA queue | `src $1B84 / bank $1BB4 / vram $1BE4 / vmain $1C14 / size $1C44`, len `$CE`, dirty flag `$26` |
| Queue drain | `$80:9E7B` (`BIT $26; BVS $9ECE; LDA $CE; BEQ $9ECB; …`), zeroes `$CE` at `$9EBF` |
| Scroll dispatcher | `$80:A93F` (`PHD; LDA #$0000; TCD …`), reached via pointer at `$80:A93C`; moves camera 1 px/call |
| Task scheduler | cooperative; tasks `$1180,X`, saved SPs `$11B0,X`; main loop `$8340-$8398`; `WAI` at `$8371`; **per-frame tick `$20/$22`** incremented at `$8372`; `JSL $80BD1F` at `$837C` |
| Camera (pixels) | `$1B6A` / `$1B6C` |
| Guards | `$0E` game-state (`2` = in a level); `$0D25` player-active (`0` during level load) |

---

## 6. Debugging journey (bugs found & fixed)

The first builds crashed/hung. Diagnosed entirely with **Mesen headless tracing**:

1. **Ran during level load.** Guard was only `$0E == 2`, which includes the load
   phase. → Added `$0D25 != 0` (player-active) guard.
2. **Pinned the VRAM queue → deadlock.** Hooking the dispatcher and appending to the
   queue left `$CE != 0`; the game's *"wait for queue empty"* spin-waits (`$80:8372`
   scheduler, `$80:A545` load) never completed. → Moved the **enqueue into the drain
   hook** so the drain DMAs our entries and zeroes `$CE`.
3. **Starved the main loop.** The dispatcher is NMI-driven and called many times per
   frame, so the heavy gather ran repeatedly in vblank and the game's tasks never got
   CPU (camera frozen). → **Gated the gather to once per frame** via tick `$20`.
   (An attempt to gather at an active-display point `$80:837C`/`$BD1F` crashed at
   **boot** because wrapping it shifts the cooperative scheduler's task stack pointers
   — reverted.)
4. **Clobbered the dispatcher's return.** The gather trampoline didn't preserve
   `A/X/Y`, which the dispatcher's caller uses. → Preserve `A/X/Y` across the gather.
5. **Wrong tilemap coordinate space.** The first visual bsnes-hd test showed the
   filled strips appearing inside the 4:3 viewport. The hook used `world_col & 63`
   and `world_row & 31`, but the game uses a BG1 ring buffer: `$1B76/$1B7A` are the
   tilemap col/row for the camera's top-left tile. → Destination columns and colbuf
   rows now use `$1B76 + strip_offset` and `$1B7A + row_offset`, while map reads still
   use the true world column/row.

Result: the hook now runs **identically to stock DX** — verified over 1500+ frames of
active scrolling in all directions, `$CE` returning to zero, no hang.

---

## 7. Tooling built (reusable)

| Tool | Purpose |
|---|---|
| `tools/asm65816.py` | Minimal two-pass 65816 **assembler** (labels, all addressing modes). Validated by round-trip through the disassembler. |
| `tools/diagnostics/re65816.py` | 65816 **disassembler** + PPU/DMA register-write **scanner**. `dis bb:aaaa N`, `scan`, `--rom`. |
| `tools/build_widescreen.py` | Assembles the hook, applies both trampolines + the routine to the DX ROM, fixes checksum, emits `mod/widescreen.ips` and a ready test ROM. |
| `tools/diagnostics/mesen_wram_probe.lua` | Dumps live WRAM (found map extent + free scratch). |
| `tools/diagnostics/mesen_ws_trace.lua` | Stability/scroll trace (catches hangs, logs camera). |
| `tools/diagnostics/mesen_ws_verify.lua` | Data-correctness check (colbuf ↔ map ↔ VRAM). |

**Mesen headless** (the key debugging unlock):
```
C:\Users\james\.codex\tmp\zamndx-research\Mesen_2.2.1\Mesen.exe --testRunner <script.lua> <rom.sfc>
```
Scripts navigate menus to gameplay, read/trace memory, write a report, then `emu.stop()`.

---

## 8. Build & test

```powershell
python tools/build_widescreen.py
```
Produces:
- `dist/Zombies Ate My Neighbors DX Widescreen.sfc` (DX + widescreen, checksum fixed)
- `mod/widescreen.ips` (stacks on the DX ROM)

Test in **standalone bsnes-hd** with `WideScreen Mode = all scenes` (+ render sprites
anywhere). Walk around and watch the leading edges fill with correct terrain.

---

## 9. Remaining work

- [x] **Data-correctness check** — `mesen_ws_verify.lua` passes (colbuf matches map,
      VRAM matches colbuf).
- [ ] **Visual confirmation in bsnes-hd** (user) — strips fill, alignment correct.
- [ ] **Tuning** — strip column count vs. vblank budget; horizontal/vertical
      alignment; behavior at level edges.
- [ ] **Sprites** — relax the OAM X-cull so active sprites draw in the strips
      (bsnes-hd already renders them; the game culls at the 256 edge). Display-only.
- [ ] **BG2** — the 32×32 second layer may need its own pass if it shows strip garbage.
- [ ] **Hosting** — decide how to run bsnes-hd alongside the analog runtime (see §3).
- [ ] **Launcher integration** — optional toggle + `build_release` staging + auto
      aspect-ratio detection, once the BG result is confirmed.
