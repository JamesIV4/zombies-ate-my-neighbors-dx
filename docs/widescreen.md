# Widescreen (optional feature) — plan & progress

Status: **BG strip-fill ROM hook is stable and data-correct in Mesen**
(`mesen_ws_verify.lua` passes with `failures=0` across all columns). Fills **10 strip
columns per side** (≈80 px). The gather is now **incremental** — only the leading
column(s) that scroll in, plus a small round-robin trickle — so per-frame cost is
bounded and independent of strip width (this replaced an every-frame full refill that
caused severe slowdown). Visual confirmation in bsnes-hd (coverage + smoothness) is the
next check. This doc captures the design, the reverse-engineering, the bugs fixed, and
what's left.

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
It maintains **`NSTRIP`=10 columns just outside the 256 px window on each side** (20
total) in VRAM, feeding the game's own VRAM-DMA queue so uploads land in vblank.

### Incremental gather (the key to staying cheap)

The camera moves ~**2 px/frame** (Mesen-measured), so a genuinely new tile column only
appears every ~4 frames. A VRAM column, once written, **persists at its ring slot as
the camera scrolls** (ring-buffer property), so re-filling all 20 columns every frame is
almost entirely wasted work — and at 20 columns it overran the CPU budget (the cause of
the severe slowdown). Instead, each frame the gather does only:
- **leading:** if the camera crossed a tile boundary this frame (`|Δcol|≥1`), gather the
  newly-exposed outermost column(s) on the leading side (capped at `LEADCAP`=3).
- **trickle:** a round-robin of `TRICKLE`=8 columns, so the rest (and especially the
  strips' top/bottom edges during **vertical** scroll, and columns after a direction
  reversal) refresh within ~3 frames.
- **full refill** only on the first gameplay frame or a ≥`FULLJMP`=4-tile jump
  (level load / warp) — a one-frame cost that's invisible behind the transition.

Per-frame work is therefore ~`leading + TRICKLE` columns (≈8–10), **independent of
`NSTRIP`**, so the strips can be made wide without re-introducing slowdown. The heavy
loop runs with **`DB=$7F`** (map/colbuf/scratch become cheap absolute accesses) and walks
the map with a running **`+$160`** row pointer instead of a per-row table lookup (the
row-base table is exactly `row*$160`).

### Two hooks

| Hook | Site | Context | Job |
|---|---|---|---|
| **GATHER** | `$80:A93F` (scroll dispatcher entry, via trampoline) | active display, **gated once/frame** | Re-run the original dispatcher, then gather the selected (leading + trickle) columns into colbufs and record each column's VRAM destination. No queue. |
| **ENQUEUE** | `$80:9E7B` (VRAM-queue drain entry, via trampoline) | vblank, cheap | Append the just-gathered colbufs to the game's VRAM-DMA queue, **mark each consumed (`$FFFF`)** so it isn't re-uploaded, set the dirty flag, then continue the original drain (which DMAs them and zeroes `$CE`). |

The split exists because the gather must stay out of vblank while VRAM uploads must
happen **in** vblank. The dispatcher is NMI-driven and called many times per frame
(1 px camera step each), so the gather is gated to run **once per frame** via tick `$20`.

### Routine + memory layout

Routine lives in free ROM at **`$8F:CC00`** (1792 free bytes; ~748 used). Scratch lives
in free high WRAM (the level map ends ~`$7F:8F00`, so `$7F:F000+` is free; the DX mailbox
at `$7F:FFF0` is already proven free):

```
$7F:F000-$F4FF   colbuf      20 columns × 64 bytes (32 tiles each), ring-ordered
$7F:F500-$F52F   scratch     cam/ring/thresh, slot state, deltas, lead window,
                             PREVCOL PREVROW REFCUR INITDONE LASTTICK
$7F:F540-$F567   VRAMDEST    20 words ($FFFF = skipped at edge / consumed by drain)
$7F:FFF0-$FFF9   (DX analog mailbox)
```

### Per-column pipeline (for a gathered column)
For strip column offset `off` (`-10..-1` and `+32..+41`) and world-col
`mc = camera_col + off`:
1. **gather:** walk 32 rows from `$7F:( camrow*$160 + mc*2 )` stepping `+$160`; apply
   priority `(cell & $1FF) < $DC → OR $2000`; store ring-ordered into
   `colbuf[ ($1B7A + row) & 31 ]`.
2. **dest:** `VRAMDEST = $1B7E + $80:9D77[(($1B76 + off) & 63)*2]`.
3. **enqueue (vblank):** queue entry `src=colbuf, bank=$7F, vram=VRAMDEST,
   vmain=$0081 (vertical +32), size=$0040`; then `VRAMDEST := $FFFF` (consumed).

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
6. **Severe slowdown + a thin unfilled strip.** The first correct build refilled *all*
   strip columns *every* frame. Widening to cover the screen (≈10 cols/side) pushed the
   per-frame gather past the CPU budget → severe slowdown; a thin outer strip was still
   unfilled. → Made the gather **incremental** (leading column + round-robin trickle;
   full refill only on load/warp) so per-frame cost is bounded and independent of strip
   width, and sped the inner loop (`DB=$7F` absolute, running `+$160` row pointer). The
   enqueue now **consumes** each column (`VRAMDEST:=$FFFF`) so only freshly-gathered
   columns re-upload. (See §4.) Camera speed was Mesen-measured at ~2 px/frame, which
   sets the leading/trickle cadence.

Result: the hook runs **identically to stock DX** and is data-correct across all 20
columns (`mesen_ws_verify.lua` `failures=0`), `$CE` returning to zero, no hang. Live
smoothness is the remaining user check.

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

**Mesen headless** (the key debugging unlock) — this build is **MesenCE**, a GUI-
subsystem app. Two gotchas that look like an instant no-op if you get them wrong:
the testrunner takes **ROM first, then script**, and the shell must **wait** for it
(`Start-Process`/`&` return immediately for a GUI app). Run it via `cmd` with stdout
redirected so the shell blocks until `emu.stop()`:
```
cmd /c '"...\Mesen_2.2.1\Mesen.exe" --testrunner "<rom.sfc>" "<script.lua>" > log.txt 2>&1'
```
The process exit code is the script's `emu.stop()` arg (here 0 = pass, 1 = failures,
2 = never reached gameplay). Scripts navigate menus to gameplay, read/trace memory,
write a report, then `emu.stop()`.

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

- [x] **Data-correctness check** — `mesen_ws_verify.lua` passes for all 20 columns
      (`failures=0`): after scrolling then holding still, colbuf and VRAM match the map.
- [x] **Strip width** — `NSTRIP`=10 columns/side (≈80 px). Cost no longer scales with
      width (incremental gather), so bump freely for ultrawide.
- [x] **Slowdown** — fixed via incremental gather + faster inner loop (§4, §6 bug 6).
- [ ] **Visual confirmation in bsnes-hd** (user) — (a) strips fill to the screen edge,
      (b) no slowdown, (c) watch the strip **corners during vertical scroll** for any
      brief stale band (trickle lag); if present, raise `TRICKLE` or add exact vertical
      streaming.
- [ ] **Tuning** — horizontal/vertical alignment; behavior at level edges.
- [ ] **Sprites** — relax the OAM X-cull so active sprites draw in the strips
      (bsnes-hd already renders them; the game culls at the 256 edge). Display-only.
- [ ] **BG2** — the 32×32 second layer may need its own pass if it shows strip garbage.
- [ ] **Hosting** — decide how to run bsnes-hd alongside the analog runtime (see §3).
- [ ] **Launcher integration** — optional toggle + `build_release` staging + auto
      aspect-ratio detection, once the BG result is confirmed.
